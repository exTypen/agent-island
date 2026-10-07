import Foundation

/// Decides which agent a message from the Inbox goes to.
/// 1. An explicit address ("@shop …", "shop, …") wins.
/// 2. Otherwise a Jev-compatible System One endpoint (Kev locally) scores every agent by its `role`.
/// 3. Without a clear winner, or with no endpoint, the island asks the user instead of guessing.
///
/// The endpoint is a LocalService: loaded when the panel opens, unloaded right after the decision by default.
/// With kevlite (github.com/exTypen/kev, lite/) a cold start is ~0.5 s, hidden while the user types.
final class Router {
    struct Decision {
        var agent: String?
        var ranked: [(id: String, p: Double)]
    }

    let cfg: RouterConfig
    private(set) var service: LocalService!

    init(_ cfg: RouterConfig) {
        self.cfg = cfg
        let health = cfg.url.flatMap(URL.init(string:))?.deletingLastPathComponent().appendingPathComponent("models")
        service = LocalService(name: "router", health: health, serve: cfg.serve, idleUnloadMinutes: cfg.idleUnloadMinutes,
                               markers: ["kev.serve", "lite/server.py"]) { [weak self] in
            self?.decide("warm up", ["a": "x", "b": "y"]) { _ in } // the first decision after a load is the slow one; pay it now
        }
    }

    var isReady: Bool { service.isReady }
    func warm() { service.warm() }
    func panelClosed() { service.panelClosed() }
    func stop() { service.stop() }

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
        service.begin()
        service.warm { [self] in
            decide(text, criteria) { probs in
                self.service.end() // decided: in unload-after-use mode this gives the RAM back now
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
                if probs == nil { self?.service.markDead() }
                done(probs)
            }
        }.resume()
    }
}
