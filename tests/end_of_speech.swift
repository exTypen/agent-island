// Check for EndOfSpeech (Voice.swift) on synthetic mic-level sequences at 50 Hz. Run from the repo root:
//   swiftc -parse-as-library -o /tmp/eos tests/end_of_speech.swift Voice.swift Service.swift Agent.swift && /tmp/eos
import Foundation

var failed = false

func run(_ name: String, _ seq: [(Float, Double)], expect: EndOfSpeech.Verdict, at: Double? = nil) {
    var e = EndOfSpeech(), t = 0.0, n = 0
    for (level, secs) in seq {
        for _ in 0..<Int(secs * 50) {
            t += 0.02; n += 1
            let v = e.feed(level + 0.03 * Float(sin(Double(n) * 1.7)), dt: 0.02) // deterministic jitter
            if v != .listening {
                let ok = v == expect && (at.map { abs(t - $0) < 0.15 } ?? true)
                print("\(ok ? "ok  " : "FAIL") \(name): \(v) at \(String(format: "%.2f", t))s")
                failed = failed || !ok
                return
            }
        }
    }
    let ok = expect == .listening
    print("\(ok ? "ok  " : "FAIL") \(name): still listening after \(String(format: "%.1f", t))s")
    failed = failed || !ok
}

@main
enum EndOfSpeechCheck {
    static func main() {
        // quiet room ≈ 0.08 with speech ≈ 0.6; noisy café ≈ 0.35 with speech ≈ 0.75
        run("talk, then pause", [(0.08, 0.5), (0.6, 2), (0.08, 3)], expect: .done, at: 2.5 + 1.1)
        run("short pauses mid-sentence don't end it", [(0.08, 0.3), (0.6, 1), (0.08, 0.6), (0.6, 1), (0.08, 0.7), (0.6, 1)], expect: .listening)
        run("noisy room, then pause", [(0.35, 1), (0.75, 2), (0.35, 3)], expect: .done, at: 3 + 1.1)
        run("talking from the first instant", [(0.6, 1.5), (0.08, 2)], expect: .done, at: 1.5 + 1.1)
        run("a cough isn't speech", [(0.08, 1), (0.6, 0.1), (0.08, 9)], expect: .nothingSaid, at: 8)
        run("nothing said", [(0.08, 10)], expect: .nothingSaid, at: 8)
        exit(failed ? 1 : 0)
    }
}
