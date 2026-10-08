"""Local Whisper for Agent Island: the final transcript after you talk, run on Apple Silicon with MLX.

The island starts this when you start talking (it's ready in ~1 s, before you've finished) and stops it once the
transcript is back, so no model sits in memory while idle. Setup, once:

    cd stt && uv venv && uv pip install -r requirements.txt

    POST /transcribe?language=tr&hotwords=<one per line>   body: float32 little-endian PCM, 16 kHz mono
         -> {"text": "...", "speech": true, "ms": 240}   (speech false and empty text when nobody spoke)
    GET  /health
"""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

import mlx.core as mx
import numpy as np
from huggingface_hub import snapshot_download
from mlx_audio.stt import load

ap = argparse.ArgumentParser()
ap.add_argument("--model", default="mlx-community/whisper-large-v3-turbo-asr-fp16")
ap.add_argument("--host", default="127.0.0.1")
ap.add_argument("--port", type=int, default=8010)
args = ap.parse_args()

t0 = time.time()
try:   # use the local copy without asking the Hub (saves ~1 s per start); download only the first time
    path = snapshot_download(args.model, local_files_only=True)
except Exception:
    path = snapshot_download(args.model)
model = load(path)
model.generate(np.zeros(16000, dtype=np.float32), language="en")   # compile the kernels before the first real request
print(f"whisper {args.model} ready in {time.time() - t0:.2f}s on {args.host}:{args.port}", flush=True)


# Whisper invents text for silence or noise: Turkish silence famously comes out as "Altyazı M.K.". So audio without
# speech never reaches the model, and the stock phrases it falls back on are dropped if they slip through anyway.
FRAME = 480  # 30 ms at 16 kHz
HALLUCINATIONS = {"altyazı m.k.", "altyazı m.k", "abone olmayı unutmayın.", "thanks for watching!", "thank you.",
                  "thank you for watching.", "you", "!", ".", "..."}


def voiced(audio):
    """The part of the recording with speech in it (padded by 0.3 s), or None when nobody spoke. Speech = 30 ms frames
    12 dB over the room's own floor (its 10th-percentile level) and above -45 dBFS, in runs of at least 90 ms, adding up
    to at least 0.25 s."""
    n = len(audio) // FRAME
    if n == 0: return None
    db = 20 * np.log10(np.sqrt((audio[:n * FRAME].reshape(n, FRAME) ** 2).mean(axis=1)) + 1e-9)
    on = db > max(np.percentile(db, 10) + 12, -45)
    # Syllables last; clicks and taps don't: count only runs of 3+ loud frames (≥ 90 ms).
    edges = np.flatnonzero(np.diff(np.concatenate([[0], on.astype(int), [0]])))
    runs = [(a, b) for a, b in zip(edges[::2], edges[1::2]) if b - a >= 3]
    if sum(b - a for a, b in runs) * 0.03 < 0.25: return None
    on = np.zeros_like(on)
    for a, b in runs: on[a:b] = True
    idx = np.flatnonzero(on)
    a, b = max(idx[0] - 10, 0), min(idx[-1] + 11, n)
    return audio[a * FRAME:b * FRAME]


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if urlparse(self.path).path != "/health": return self._send(404, {"error": "not found"})
        self._send(200, {"model": args.model})

    def do_POST(self):
        url = urlparse(self.path)
        if url.path != "/transcribe": return self._send(404, {"error": "not found"})
        q = parse_qs(url.query)
        t = time.time()
        audio = np.frombuffer(self.rfile.read(int(self.headers.get("content-length", 0))), dtype="<f4")
        audio = voiced(audio)
        if audio is None: return self._send(200, {"text": "", "speech": False, "ms": round((time.time() - t) * 1000)})
        kw = {"language": q.get("language", [None])[0], "temperature": 0.0}   # no temperature fallback: it only gets more inventive
        hot = [w for w in q.get("hotwords", [""])[0].split("\n") if w.strip()]
        if hot: kw["hotwords"] = hot
        out = model.generate(audio, **kw)
        text = out.text.strip()
        if text.lower() in HALLUCINATIONS: text = ""
        self._send(200, {"text": text, "speech": True, "ms": round((time.time() - t) * 1000)})

    def log_message(self, *a):
        pass


HTTPServer((args.host, args.port), Handler).serve_forever()   # one request at a time: MLX isn't shared across threads
