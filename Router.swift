import Foundation

/// Decides which agent a message from the Inbox goes to.
/// 1. An explicit address ("@shop …", "shop, …") wins.
/// 2. Otherwise a Jev-compatible System One endpoint (Kev locally) scores every agent by its `role`.
/// 3. Without a clear winner, or with no endpoint, the island asks the user instead of guessing.
///
/// The endpoint is loaded on demand (panel opened, message routed) and, by default, unloaded again
/// as soon as the decision is made or the panel closes, so an idle island holds no model in memory.
/// With kevlite (github.com/exTypen/kev, lite/) a cold start is ~0.5 s, hidden by warming on panel open.
final class Router {
    struct Decision {
        var agent: String?
        var ranked: [(id: String, p: Double)]
    }

    private enum State { case off, starting, ready }

    let cfg: RouterConfig
    private var state = State.off
    private var server: Process?
    private var waiters: [() -> Void] = []
    private var lastUse = Date()
    private var inFlight = 0 // routes waiting on or talking to the endpoint
    private var idleTimer: Timer?
    private let pidURL = configDir.appendingPathComponent("router.pid")

    var isReady: Bool { state == .ready }

    init(_ cfg: RouterConfig) {
        self.cfg = cfg
        reapStale()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.checkIdle() }
    }

    /// nil = keep loaded; 0 = unload right after use.
    private var idleLimit: TimeInterval? {
        let m = cfg.idleUnloadMinutes ?? 0
        return m < 0 ? nil : m * 60
    }

    /// The panel closed: in unload-after-use mode, let the model go unless a route still needs it.
    func panelClosed() {
        if idleLimit == 0, inFlight == 0, server != nil { stop() }
    }

    private var modelsURL: URL? { cfg.url.flatMap(URL.init(string:))?.deletingLastPathComponent().appendingPathComponent("models") }

    // MARK: lifecycle

    /// Make sure the endpoint is up; `then` runs once it answers (or once starting it has failed).
    func warm(then: (() -> Void)? = nil) {
        lastUse = Date()
        if state == .ready { then?(); return }
        if let then { waiters.append(then) }
        guard state == .off else { return }
        state = .starting
        // A server someone started by hand is used as is, and never unloaded by us.
        probe { [self] up in
            if up { return becameReady() }
            guard let cmd = cfg.serve else { return failed() }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
            let log = configDir.appendingPathComponent("router.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            p.standardOutput = try? FileHandle(forWritingTo: log)
            p.standardError = p.standardOutput
            do { try p.run() } catch { return failed() }
            server = p
            try? "\(p.processIdentifier)".write(to: pidURL, atomically: true, encoding: .utf8)
            poll(until: Date() + 90)
        }
    }

    private func poll(until deadline: Date) {
        probe { [self] up in
            if up { return becameReady() }
            guard server?.isRunning == true, Date() < deadline else { stop(); return failed() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.poll(until: deadline) }
        }
    }

    private func becameReady() {
        state = .ready
        decide("warm up", ["a": "x", "b": "y"]) { _ in } // the first decision after a load is ~2 s; pay it now
        flushWaiters()
    }

    private func failed() {
        state = .off
        flushWaiters()
    }

    private func flushWaiters() {
        let w = waiters
        waiters = []
        w.forEach { $0() }
    }

    private func probe(_ done: @escaping (Bool) -> Void) {
        guard let url = modelsURL else { return done(false) }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 1)) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { done(ok) }
        }.resume()
    }

    private func checkIdle() {
        // In unload-after-use mode this is only the safety net for a panel left open without sending anything.
        guard state == .ready, server != nil, let limit = idleLimit,
              inFlight == 0, Date().timeIntervalSince(lastUse) > (limit == 0 ? 120 : limit) else { return }
        stop()
    }

    /// Stops a server we started: `uv` and the Python process under it.
    func stop() {
        if let p = server { kill(tree: p.processIdentifier) }
        server = nil
        state = .off
        try? FileManager.default.removeItem(at: pidURL)
    }

    /// A server left behind by an island that was killed rather than quit.
    private func reapStale() {
        guard let s = try? String(contentsOf: pidURL, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        let cmd = Router.command(of: pid)
        if cmd.contains("kev.serve") || cmd.contains("lite/server.py") { kill(tree: pid) }
        try? FileManager.default.removeItem(at: pidURL)
    }

    private func kill(tree pid: Int32) {
        let pk = Process()
        pk.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pk.arguments = ["-TERM", "-P", "\(pid)"]
        try? pk.run()
        pk.waitUntilExit()
        Darwin.kill(pid, SIGTERM)
    }

    private static func command(of pid: Int32) -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "command=", "-p", "\(pid)"]
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: routing

    static func addressed(_ text: String, _ agents: [AgentConfig]) -> AgentConfig? {
        let t = text.lowercased()
        return agents.first { a in
            [a.id, a.name.lowercased()].contains { n in
                t.hasPrefix("@" + n) || t.hasPrefix(n + ",") || t.hasPrefix(n + ":")
            }
        }
    }

    func route(_ text: String, _ agents: [AgentConfig], _ done: @escaping (Decision) -> Void) {
        let fallback = Decision(agent: nil, ranked: agents.map { ($0.id, 0) })
        if let a = Router.addressed(text, agents) { return done(Decision(agent: a.id, ranked: [])) }
        guard cfg.url != nil else { return done(fallback) }
        let criteria = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.role ?? $0.name) })
        inFlight += 1
        warm { [self] in
            decide(text, criteria) { probs in
                self.inFlight -= 1
                if self.idleLimit == 0, self.inFlight == 0 { self.stop() } // decided: give the RAM back now
                var d = fallback
                if let probs, !probs.isEmpty {
                    d.ranked = agents.map { ($0.id, probs[$0.id] ?? 0) }.sorted { $0.p > $1.p }
                    let top = d.ranked[0], runnerUp = d.ranked.count > 1 ? d.ranked[1].p : 0
                    if top.p >= self.cfg.minConfidence ?? 0.5, top.p - runnerUp >= self.cfg.minMargin ?? 0.2 { d.agent = top.id }
                }
                done(d)
            }
        }
    }

    /// One System One `choice` call; nil when the endpoint didn't answer.
    private func decide(_ state: String, _ criteria: [String: String], _ done: @escaping ([String: Double]?) -> Void) {
        guard let s = cfg.url, let url = URL(string: s) else { return done(nil) }
        lastUse = Date()
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "state": state, "model": "kev-latest",
            "questions": ["agent": ["type": "choice", "instructions": "Which teammate should handle this request?",
                                    "criteria": criteria]],
        ])
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let answer = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
                .flatMap { ($0["answers"] as? [String: Any])?["agent"] as? [String: Any] }
            let probs = answer?["probabilities"] as? [String: Double]
            DispatchQueue.main.async {
                if probs == nil, self?.state == .ready { self?.stop() } // it died or hung; restart clean next time
                done(probs)
            }
        }.resume()
    }
}
