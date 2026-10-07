import AVFoundation
import Foundation
import Speech

// MARK: - Speech (Apple's recognizer: live partial text while you talk, plus the raw audio for Whisper)

final class Speech {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var active = false // stop() may land before authorization returns
    private var running = false // engine started and tap installed
    private let recognizer: SFSpeechRecognizer?
    private let hints: [String]

    // 16 kHz mono float samples of the current recording, filled on the audio thread.
    private static let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private let lock = NSLock()

    init(locale: String? = nil, hints: [String] = []) {
        recognizer = SFSpeechRecognizer(locale: locale.map(Locale.init(identifier:)) ?? .current) ?? SFSpeechRecognizer()
        self.hints = hints
    }

    /// Calls back on main with partial transcripts, or an error string.
    func start(level: @escaping (Float) -> Void, _ cb: @escaping (String, String?) -> Void) {
        active = true
        lock.withLock { samples = [] }
        // Ask for both permissions up front: touching engine.inputNode without mic access blocks the main thread.
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async {
                    guard self.active else { return }
                    guard status == .authorized else {
                        return cb("", "Speech recognition not authorized (System Settings → Privacy → Speech Recognition)")
                    }
                    guard mic else { return cb("", "Microphone not authorized (System Settings → Privacy → Microphone)") }
                    do { try self.begin(level, cb) } catch { cb("", error.localizedDescription) }
                }
            }
        }
    }

    private func begin(_ level: @escaping (Float) -> Void, _ cb: @escaping (String, String?) -> Void) throws {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.contextualStrings = hints // nudges the live text toward the same vocabulary Whisper gets
        request = req
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        // No mic access (or no input device) reports a 0 Hz format, and installTap would raise and abort the app.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "mic", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Microphone unavailable — allow Agent Island in System Settings → Privacy → Microphone"])
        }
        let converter = AVAudioConverter(from: format, to: Speech.whisperFormat)
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] b, _ in
            req.append(b)
            self?.capture(b, converter)
            guard let ch = b.floatChannelData?[0], b.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(b.frameLength) { sum += ch[i] * ch[i] }
            let db = 20 * log10(max(sqrt(sum / Float(b.frameLength)), 1e-6)) // ≈ -60 silence … 0 loud
            let l = min(max((db + 55) / 45, 0), 1)
            DispatchQueue.main.async { level(l) }
        }
        engine.prepare()
        try engine.start()
        running = true
        task = recognizer?.recognitionTask(with: req) { result, _ in
            if let result { DispatchQueue.main.async { cb(result.bestTranscription.formattedString, nil) } }
        }
    }

    private func capture(_ b: AVAudioPCMBuffer, _ converter: AVAudioConverter?) {
        guard let converter else { return }
        let cap = AVAudioFrameCount(Double(b.frameLength) * 16000 / b.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Speech.whisperFormat, frameCapacity: cap) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return b
        }
        guard let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        lock.withLock { samples += chunk }
    }

    /// Stops listening; returns the recording as 16 kHz mono float samples.
    @discardableResult
    func stop() -> [Float] {
        guard active else { return [] }
        active = false
        if running {
            running = false
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task = nil
        request = nil
        return lock.withLock { samples }
    }
}

// MARK: - Whisper (local, on demand: loads when you start talking, unloads after the transcript)

final class Whisper {
    let cfg: WhisperConfig
    let service: LocalService
    private var holding = false // between warm() and transcribe()/cancel(): keeps the model loaded while you talk
    private var base: URL { URL(string: cfg.url ?? "http://127.0.0.1:8010")! }

    init(_ cfg: WhisperConfig) {
        self.cfg = cfg
        let base = URL(string: cfg.url ?? "http://127.0.0.1:8010")!
        service = LocalService(name: "whisper", health: base.appendingPathComponent("health"), serve: cfg.serve,
                               idleUnloadMinutes: cfg.idleUnloadMinutes, markers: ["stt/server.py"])
    }

    /// Recording started: start loading the model now, so it's ready when the user lets go.
    func warm() {
        guard !holding else { return }
        holding = true
        service.begin()
        service.warm()
    }

    /// Recording discarded (a tap, an error).
    func cancel() {
        guard holding else { return }
        holding = false
        service.end()
    }

    /// nil when Whisper couldn't produce a transcript; the caller keeps Apple's text then.
    func transcribe(_ samples: [Float], hotwords: [String], _ done: @escaping (String?) -> Void) {
        if !holding { holding = true; service.begin() }
        service.warm { [self] in
            var comps = URLComponents(url: base.appendingPathComponent("transcribe"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "language", value: cfg.language)]
                + (hotwords.isEmpty ? [] : [URLQueryItem(name: "hotwords", value: hotwords.joined(separator: "\n"))])
            var req = URLRequest(url: comps.url!, timeoutInterval: 30)
            req.httpMethod = "POST"
            req.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
            req.httpBody = samples.withUnsafeBufferPointer { Data(buffer: $0) } // float32, little-endian, 16 kHz mono
            URLSession.shared.dataTask(with: req) { data, _, _ in
                let text = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["text"] as? String
                DispatchQueue.main.async {
                    if text == nil { self.service.markDead() }
                    self.holding = false
                    self.service.end()
                    done(text?.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }.resume()
        }
    }

    func stop() { service.stop() }
}

// MARK: - Vocabulary

/// Words the recognizers should expect: the config's `voice.vocabulary` first, then agent names and the technical
/// terms in their roles (product names, camelCase, dotted or hyphenated names, acronyms). Whisper's prompt holds
/// ~224 tokens, so the list is capped.
func voiceVocabulary(_ cfg: Config) -> [String] {
    var out = cfg.voice?.vocabulary ?? []
    let term = try! NSRegularExpression(pattern: #"(?<![.!?]\s)(?<!^)\b[A-Z][A-Za-z0-9]*(?:[.\-+#][A-Za-z0-9]+)*\b|\b[a-z]+[A-Z][A-Za-z0-9]*\b|\b[a-z0-9]+(?:[.\-][a-z0-9]+)+\b"#)
    for a in cfg.agents {
        out.append(a.name)
        let text = [a.role, a.instructions].compactMap { $0 }.joined(separator: " ")
        let ns = text as NSString
        for m in term.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let w = ns.substring(with: m.range)
            if w.count > 2 { out.append(w) }
        }
    }
    var seen = Set<String>()
    return Array(out.filter { seen.insert($0.lowercased()).inserted }.prefix(60))
}
