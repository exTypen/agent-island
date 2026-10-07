import Foundation

/// A local model server the island starts on demand and stops when it isn't needed: the router's decision model and
/// Whisper. Callers bracket each use with `begin()` / `end()`; with `idle_unload_minutes: 0` (the default) the server
/// stops as soon as nothing is using it, so an idle island holds no model in memory.
final class LocalService {
    private enum State { case off, starting, ready }

    let name: String
    private let health: URL?
    private let serve: String?
    private let idleMinutes: Double
    private let markers: [String] // substrings of the server's command line, to recognise a stale one by pid
    private let onReady: () -> Void

    private var state = State.off
    private var server: Process?
    private var waiters: [() -> Void] = []
    private var lastUse = Date()
    private var inFlight = 0
    private var idleTimer: Timer?
    private var pidURL: URL { configDir.appendingPathComponent("\(name).pid") }

    var isReady: Bool { state == .ready }

    /// `idleUnloadMinutes`: 0 = unload right after use, negative = keep loaded, else minutes without use.
    init(name: String, health: URL?, serve: String?, idleUnloadMinutes: Double?, markers: [String], onReady: @escaping () -> Void = {}) {
        self.name = name
        self.health = health
        self.serve = serve
        self.idleMinutes = idleUnloadMinutes ?? 0
        self.markers = markers
        self.onReady = onReady
        reapStale()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.checkIdle() }
    }

    // MARK: use

    func begin() {
        inFlight += 1
        lastUse = Date()
    }

    func end() {
        inFlight = max(inFlight - 1, 0)
        lastUse = Date()
        if idleMinutes == 0, inFlight == 0, server != nil { stop() }
    }

    /// A request failed: the server died or hung. Restart it clean next time.
    func markDead() {
        if state == .ready { stop() }
    }

    /// The panel closed: in unload-after-use mode, let the model go unless something still needs it.
    func panelClosed() {
        if idleMinutes == 0, inFlight == 0, server != nil { stop() }
    }

    // MARK: lifecycle

    /// Make sure the server is up; `then` runs once it answers (or once starting it has failed).
    func warm(then: (() -> Void)? = nil) {
        lastUse = Date()
        if state == .ready { then?(); return }
        if let then { waiters.append(then) }
        guard state == .off else { return }
        state = .starting
        // A server someone started by hand is used as is, and never stopped by us.
        probe { [self] up in
            if up { return becameReady() }
            guard let cmd = serve else { return failed() }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
            let log = configDir.appendingPathComponent("\(name).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            p.standardOutput = try? FileHandle(forWritingTo: log)
            p.standardError = p.standardOutput
            do { try p.run() } catch { return failed() }
            server = p
            try? "\(p.processIdentifier)".write(to: pidURL, atomically: true, encoding: .utf8)
            poll(until: Date() + 120)   // a first start may download the model
        }
    }

    private func poll(until deadline: Date) {
        probe { [self] up in
            if up { return becameReady() }
            guard server?.isRunning == true, Date() < deadline else { stop(); return failed() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.poll(until: deadline) }
        }
    }

    private func becameReady() {
        state = .ready
        onReady()
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
        guard let health else { return done(false) }
        URLSession.shared.dataTask(with: URLRequest(url: health, timeoutInterval: 1)) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { done(ok) }
        }.resume()
    }

    private func checkIdle() {
        // In unload-after-use mode this is only the safety net for a panel left open without using the model.
        guard state == .ready, server != nil, idleMinutes >= 0, inFlight == 0,
              Date().timeIntervalSince(lastUse) > (idleMinutes == 0 ? 120 : idleMinutes * 60) else { return }
        stop()
    }

    /// Stops a server we started, and anything it spawned.
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
        let cmd = LocalService.command(of: pid)
        if markers.contains(where: cmd.contains) { kill(tree: pid) }
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
}
