"""Local Whisper for Agent Island: the final transcript after you talk, run on Apple Silicon with MLX.

The island starts this when you start talking (it's ready in ~1 s, before you've finished) and stops it once the
transcript is back, so no model sits in memory while idle. Setup, once:

    cd stt && uv venv && uv pip install -r requirements.txt

    POST /transcribe?language=tr&hotwords=<one per line>   body: float32 little-endian PCM, 16 kHz mono
         -> {"text": "...", "ms": 240}
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
        if audio.size < 1600: return self._send(200, {"text": "", "ms": 0})   # under 0.1 s: nothing said
        kw = {"language": q.get("language", [None])[0]}
        hot = [w for w in q.get("hotwords", [""])[0].split("\n") if w.strip()]
        if hot: kw["hotwords"] = hot
        out = model.generate(audio, **kw)
        self._send(200, {"text": out.text.strip(), "ms": round((time.time() - t) * 1000)})

    def log_message(self, *a):
        pass


HTTPServer((args.host, args.port), Handler).serve_forever()   # one request at a time: MLX isn't shared across threads
