import AppKit
import SwiftUI

// MARK: - Config (~/.config/agent-island/agents.yaml)

struct Defaults: Decodable, Equatable {
    var model: String?
    var permissionMode: String?
    var compactAt: Int?
    /// How agents refer to you ("Alex"); default "the user".
    var user: String?
    /// Reply language / style for every agent ("German", "Turkish prose, English technical terms"); default: yours.
    var language: String?
    /// Speech recognition locale for dictation ("en-US", "tr-TR"); default: the system's.
    var voiceLocale: String?
}

struct AgentConfig: Decodable, Equatable {
    var id: String
    var name: String
    var role: String?
    var cwd: String? // YAML reads a bare `~` as null, so missing means home
    var dir: String { cwd ?? "~" }
    var color: String?
    var model: String?
    var permissionMode: String?
    var compactAt: Int?
    var addDirs: [String]?
    var instructions: String?
    /// The agent that manages the island: it gets island-guide.md (how the app works, how to edit this file).
    var manager: Bool?
}

struct RouterConfig: Decodable, Equatable {
    /// A Jev-compatible System One endpoint (Kev, Von, Laya…). Missing = always ask which agent.
    var url: String?
    /// Shell command that starts the endpoint; the island runs it at launch and stops it on quit.
    var serve: String?
    var minConfidence: Double? // default 0.5
    /// Lead the top agent needs over the runner-up (default 0.2). With two agents the top pick is
    /// always ≥ 0.5, so probability alone can't tell "sure" from "coin flip"; the margin can.
    var minMargin: Double?
    /// Unload after this many idle minutes. 0 (default) = right after each decision and when the panel
    /// closes; it reloads (~0.5 s with kevlite) when the panel opens, while you type. Negative = keep it loaded.
    var idleUnloadMinutes: Double?
}

struct WhisperConfig: Decodable, Equatable {
    var url: String?            // default http://127.0.0.1:8010
    var serve: String?          // command that starts stt/server.py
    var language: String?       // "tr", "en"…; default: Whisper detects it
    var idleUnloadMinutes: Double?
}

struct VoiceConfig: Decodable, Equatable {
    /// Words dictation should get right: tools, products, names. Agent names and role terms are added automatically.
    var vocabulary: [String]?
    /// Local Whisper for the final transcript; without it Apple's recognizer alone is used.
    var whisper: WhisperConfig?
}

struct Config: Decodable {
    var defaults: Defaults?
    var router: RouterConfig?
    var voice: VoiceConfig?
    var agents: [AgentConfig]
}

let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/agent-island")
let configURL = configDir.appendingPathComponent("agents.yaml")
private let sessionsURL = configDir.appendingPathComponent("sessions.json")

func expandPath(_ p: String) -> String { (p as NSString).expandingTildeInPath }

/// How the island works and how to manage it; appended to the system prompt of the `manager: true` agent.
let islandGuide: String = Bundle.main.url(forResource: "island-guide", withExtension: "md")
    .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

/// YAML via the system Ruby (ships with macOS) so the app needs no YAML dependency.
func loadConfig() throws -> Config {
    if !FileManager.default.fileExists(atPath: configURL.path) {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        if let bundled = Bundle.main.url(forResource: "agents", withExtension: "yaml") {
            try FileManager.default.copyItem(at: bundled, to: configURL)
        }
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
    p.arguments = ["-ryaml", "-rjson", "-e", "puts JSON.dump(YAML.load_file(ARGV[0]))", configURL.path]
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw NSError(domain: "agents.yaml", code: 1, userInfo: [
            NSLocalizedDescriptionKey: String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "parse error",
        ])
    }
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try d.decode(Config.self, from: data)
}

/// agent id → Claude Code session id, so each agent keeps its memory across app restarts.
enum Sessions {
    static func load() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: sessionsURL))) ?? [:]
    }

    static func save(_ id: String, _ session: String?) {
        var all = load()
        all[id] = session
        try? JSONEncoder().encode(all).write(to: sessionsURL)
    }
}

extension Color {
    init(hex: String?) {
        let v = UInt32((hex ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xD97757
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Agent

enum Role { case user, assistant, system }

struct Message: Identifiable {
    let id = UUID()
    let role: Role
    var text: String
}

/// Something the agent is blocked on: a tool permission or an AskUserQuestion.
struct Pending: Identifiable {
    struct Question {
        let text: String
        let header: String?
        let options: [(label: String, detail: String?)]
    }

    let id: String // control request_id
    let tool: String
    let input: [String: Any]
    let summary: String
    let questions: [Question] // empty = a permission prompt
    let suggestions: [Any] // "always allow" rules Claude Code proposes
    var answers: [String: String] = [:]
    let date = Date()

    var isQuestion: Bool { !questions.isEmpty }
    var current: Question? { questions.first { answers[$0.text] == nil } }
}

/// A subagent / background job the orchestrator started.
struct TaskInfo: Identifiable {
    let id: String // tool_use_id of the Agent/Bash call that started it
    var title: String
    var detail: String?
    var background: Bool
    var state = "running" // running | completed | failed | killed
}

/// One agent: a long-lived `claude -p --input-format stream-json` process in its own cwd.
/// Messages can be written at any time (Claude Code queues them), so the user never waits on a turn.
final class Agent: ObservableObject, Identifiable {
    private(set) var cfg: AgentConfig
    private(set) var defaults: Defaults
    var color: Color { Color(hex: cfg.color) }
    var id: String { cfg.id }

    @Published var messages: [Message] = []
    @Published var turnRunning = false
    @Published var status: String? // "compacting"
    @Published var tasks: [TaskInfo] = []
    @Published var contextTokens = 0
    @Published var unread = false
    @Published var pending: [Pending] = []
    /// Finished turns / failures while nobody was looking; the island collects these into the Inbox.
    var onReport: (_ text: String, _ failed: Bool) -> Void = { _, _ in }

    var isVisible: () -> Bool = { false }
    var onTurnEnd: () -> Void = {}
    var busy: Bool { turnRunning || status != nil || tasks.contains { $0.state == "running" } }
    var needsInput: Bool { !pending.isEmpty }

    private var proc: Process?
    private var stdin: FileHandle?
    private var replyIndex: Int?
    private var turnText = "" // what this turn said, for the Inbox
    private var initialized = false // got `init` from the current process
    private var sessionID: String? { didSet { if sessionID != oldValue { Sessions.save(id, sessionID) } } }

    init(_ cfg: AgentConfig, defaults: Defaults, session: String?) {
        self.cfg = cfg
        self.defaults = defaults
        sessionID = session
        if let session { loadTranscript(session) }
    }

    /// Restore the visible conversation of a resumed session from Claude Code's own transcript.
    private func loadTranscript(_ session: String) {
        let slug = expandPath(cfg.dir).replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(slug)/\(session).jsonl")
        DispatchQueue.global(qos: .utility).async {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            var out: [Message] = []
            for line in text.split(separator: "\n") {
                guard let e = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      e["isSidechain"] as? Bool != true, e["isMeta"] as? Bool != true,
                      e["isCompactSummary"] as? Bool != true else { continue }
                let content = (e["message"] as? [String: Any])?["content"]
                if e["type"] as? String == "user", let s = content as? String, !s.hasPrefix("<"), s != "/compact" {
                    out.append(Message(role: .user, text: s))
                } else if e["type"] as? String == "assistant" {
                    let t = (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                        .joined(separator: "\n\n")
                    guard !t.isEmpty else { continue }
                    if out.last?.role == .assistant { out[out.count - 1].text += "\n\n" + t } else { out.append(Message(role: .assistant, text: t)) }
                }
            }
            DispatchQueue.main.async {
                guard self.messages.isEmpty else { return }
                self.messages = Array(out.suffix(40))
            }
        }
    }

    var systemPrompt: String {
        let user = defaults.user ?? "the user"
        return """
        You are "\(cfg.name)", one of \(user)'s AI teammates, reached through Agent Island, a small macOS edge panel. \(cfg.role ?? "")
        \(user) talks only to you. You are an orchestrator, not a solo worker:
        - For real work, delegate each independent job to its own background subagent (Agent tool, run_in_background: true) with a self-contained prompt: goal, relevant paths, constraints, what to report back. Then reply right away with one short line saying what you started. Never block the conversation on long work yourself.
        - \(user) may send new requests while subagents run; treat them the same way. Answer quick questions directly.
        - You are notified when a subagent finishes. Check its result, then report concisely: what was done, what changed, anything needing a decision. Report each result exactly once; if a notification only repeats something you already reported, reply with just "✓".
        - Keep your own context lean: subagents do the broad reading, searching and editing; you keep conclusions. The island compacts your session when it grows.
        - When you need a decision from \(user), ask with the AskUserQuestion tool (2–4 concrete options) instead of a question in prose; it shows up as a card answered with one key.
        - The panel is small: keep answers short, no long code dumps unless asked. \(defaults.language.map { "Reply in \($0)." } ?? "Reply in the language \(user) writes in.")
        \(cfg.instructions ?? "")
        \(cfg.manager == true ? islandGuide : "")
        """
    }

    // MARK: input

    func send(_ text: String) {
        messages.append(Message(role: .user, text: text))
        replyIndex = nil
        write(["type": "user", "message": ["role": "user", "content": text]])
    }

    func compact() {
        guard status == nil else { return }
        messages.append(Message(role: .system, text: "compacting context…"))
        write(["type": "user", "message": ["role": "user", "content": "/compact"]])
    }

    func interrupt() {
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    /// New config from a reload. The system prompt and flags only apply at launch, so the process restarts (same
    /// session, via --resume) once nothing is in flight; killing it mid-turn would also kill its subagents.
    func update(_ cfg: AgentConfig, defaults: Defaults) {
        guard cfg != self.cfg || defaults != self.defaults else { return }
        self.cfg = cfg
        self.defaults = defaults
        restartWhenIdle = proc != nil
        restartIfIdle()
    }

    private var restartWhenIdle = false

    private func restartIfIdle() {
        guard restartWhenIdle, !busy, pending.isEmpty else { return }
        restartWhenIdle = false
        stop()
    }

    /// Answer a pending permission prompt or question.
    func respond(_ p: Pending, allow: Bool, always: Bool = false, message: String? = nil) {
        var response: [String: Any]
        if allow {
            var input = p.input
            if p.isQuestion { input["answers"] = p.answers }
            response = ["behavior": "allow", "updatedInput": input]
            if always, !p.suggestions.isEmpty { response["updatedPermissions"] = p.suggestions }
        } else {
            response = ["behavior": "deny", "message": message ?? "\(defaults.user ?? "The user") declined this."]
        }
        write(["type": "control_response",
               "response": ["subtype": "success", "request_id": p.id, "response": response]])
        withAnimation(.spring(duration: 0.3)) { pending.removeAll { $0.id == p.id } }
        let verdict = p.isQuestion ? p.answers.values.joined(separator: ", ")
            : allow ? (always ? "always allowed" : "allowed") : "denied" + (message.map { ": \($0)" } ?? "")
        messages.append(Message(role: .system, text: "\(p.isQuestion ? "answered" : p.tool) · \(verdict)"))
    }

    /// Pick option `index` of the current question; sends once every question has an answer.
    func answer(_ p: Pending, option index: Int? = nil, text: String? = nil) {
        guard var q = pending.first(where: { $0.id == p.id }), let cur = q.current else { return }
        if let index, cur.options.indices.contains(index) { q.answers[cur.text] = cur.options[index].label }
        else if let text { q.answers[cur.text] = text }
        else { return }
        if q.current == nil { respond(q, allow: true) }
        else if let i = pending.firstIndex(where: { $0.id == q.id }) { pending[i] = q }
    }

    func newSession() {
        stop()
        sessionID = nil
        messages = []
        tasks = []
        contextTokens = 0
    }

    func stop() {
        pending = []
        stdin = nil
        proc?.terminate()
        proc = nil
    }

    private func write(_ obj: [String: Any]) {
        if proc?.isRunning != true { launch() }
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        d.append(0x0A)
        try? stdin?.write(contentsOf: d)
    }

    // MARK: process

    private func launch() {
        let p = Process()
        // Login shell so a Finder-launched app still finds `claude` on the user's PATH.
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        var args = [
            "-lc", "exec claude \"$@\"", "zsh", "-p",
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--permission-mode", cfg.permissionMode ?? defaults.permissionMode ?? "auto",
            // Prompts the permission mode can't settle, and AskUserQuestion, come to us as control_requests.
            "--permission-prompt-tool", "stdio",
            "--append-system-prompt", systemPrompt,
        ]
        if let m = cfg.model ?? defaults.model { args += ["--model", m] }
        for dir in cfg.addDirs ?? [] { args += ["--add-dir", expandPath(dir)] }
        if let s = sessionID {
            args += ["--resume", s]
        }
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: expandPath(cfg.dir))
        let inPipe = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = inPipe
        p.standardOutput = out
        p.standardError = err

        var buf = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            buf.append(h.availableData)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf[buf.startIndex..<nl]
                buf.removeSubrange(buf.startIndex...nl)
                if let ev = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    DispatchQueue.main.async { self?.handle(ev) }
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self, self.proc === proc else { return }
                self.proc = nil
                self.stdin = nil
                self.turnRunning = false
                self.status = nil
                self.pending = []
                if proc.terminationStatus != 0 {
                    self.messages.append(Message(role: .system, text: "session exited: \(stderr.suffix(300))"))
                    self.onReport("session exited: \(stderr.suffix(200))", true)
                    // Only a resume Claude Code itself rejects is dropped; any other early exit (killed, crashed, offline) keeps the
                    // session so the agent's memory isn't lost to a transient failure.
                    if !self.initialized, stderr.contains("No conversation found") { self.sessionID = nil }
                }
            }
        }
        initialized = false
        do {
            try p.run()
            proc = p
            stdin = inPipe.fileHandleForWriting
        } catch {
            messages.append(Message(role: .system, text: "failed to launch claude: \(error.localizedDescription)"))
        }
    }

    // MARK: events

    private func reply(_ s: String) {
        if replyIndex == nil || replyIndex! >= messages.count {
            messages.append(Message(role: .assistant, text: ""))
            replyIndex = messages.count - 1
        }
        let i = replyIndex!
        messages[i].text += messages[i].text.isEmpty ? s : "\n\n" + s
    }

    private func finishTask(_ toolUseID: String, _ state: String) {
        guard let i = tasks.firstIndex(where: { $0.id == toolUseID }) else { return }
        tasks[i].state = state
        restartIfIdle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) { self?.tasks.removeAll { $0.id == toolUseID && $0.state != "running" } }
        }
    }

    private func handle(_ ev: [String: Any]) {
        let type = ev["type"] as? String, subtype = ev["subtype"] as? String
        let isMain = ev["parent_tool_use_id"] as? String == nil
        switch (type, subtype) {
        case ("control_request", _):
            guard let id = ev["request_id"] as? String, let req = ev["request"] as? [String: Any],
                  req["subtype"] as? String == "can_use_tool" else { return }
            let tool = req["tool_name"] as? String ?? "tool"
            let input = req["input"] as? [String: Any] ?? [:]
            let questions = (input["questions"] as? [[String: Any]] ?? []).map { q in
                Pending.Question(
                    text: q["question"] as? String ?? "",
                    header: q["header"] as? String,
                    options: (q["options"] as? [[String: Any]] ?? []).map { ($0["label"] as? String ?? "", $0["description"] as? String) })
            }
            let what = input["command"] as? String ?? input["file_path"] as? String ?? input["url"] as? String
                ?? req["description"] as? String ?? ""
            withAnimation(.spring(duration: 0.35, bounce: 0.25)) {
                pending.append(Pending(id: id, tool: tool, input: input, summary: what,
                                       questions: tool == "AskUserQuestion" ? questions : [],
                                       suggestions: req["permission_suggestions"] as? [Any] ?? []))
            }
            onTurnEnd() // nudge the island: someone is waiting on the user
        case ("control_cancel_request", _):
            if let id = ev["request_id"] as? String { pending.removeAll { $0.id == id } }
        case ("system", "init"):
            initialized = true
            turnText = ""
            sessionID = ev["session_id"] as? String ?? sessionID
            turnRunning = true
            replyIndex = nil
        case ("system", "status"):
            status = ev["status"] as? String
        case ("system", "compact_boundary"):
            let meta = ev["compact_metadata"] as? [String: Any]
            let pre = meta?["pre_tokens"] as? Int ?? contextTokens
            contextTokens = meta?["post_tokens"] as? Int ?? 0
            messages.append(Message(role: .system, text: "context compacted · \(pre / 1000)k → \(contextTokens / 1000)k"))
        case ("system", "task_started"):
            // Background Bash the orchestrator itself launched; subagent-owned jobs stay out of the strip.
            guard ev["owned_by_subagent"] as? Bool != true, let tid = ev["tool_use_id"] as? String,
                  !tasks.contains(where: { $0.id == tid }) else { return }
            withAnimation { tasks.append(TaskInfo(id: tid, title: ev["description"] as? String ?? "task", background: true)) }
        case ("system", "task_progress"):
            if let tid = ev["tool_use_id"] as? String, let i = tasks.firstIndex(where: { $0.id == tid }) {
                tasks[i].detail = ev["description"] as? String
            }
        case ("system", "task_notification"):
            if let tid = ev["tool_use_id"] as? String { finishTask(tid, ev["status"] as? String ?? "completed") }
        case ("assistant", _) where isMain:
            let msg = ev["message"] as? [String: Any]
            if let u = msg?["usage"] as? [String: Any] {
                contextTokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                    .reduce(0) { $0 + (u[$1] as? Int ?? 0) }
            }
            for block in msg?["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.isEmpty {
                        reply(t)
                        turnText += turnText.isEmpty ? t : "\n\n" + t
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    if name == "Agent" || name == "Task", let tid = block["id"] as? String {
                        let title = input["description"] as? String ?? "subagent"
                        withAnimation {
                            tasks.append(TaskInfo(id: tid, title: title, background: input["run_in_background"] as? Bool == true))
                        }
                        reply("`⇢ \(title)`")
                    } else {
                        reply("`▸ \(name)`")
                    }
                default: break
                }
            }
        case ("user", _) where isMain:
            // A foreground subagent is done when its tool_result lands; background ones report via task_notification.
            for block in (ev["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [] {
                if let tid = block["tool_use_id"] as? String, tasks.first(where: { $0.id == tid })?.background == false {
                    finishTask(tid, block["is_error"] as? Bool == true ? "failed" : "completed")
                }
            }
        case ("result", _):
            turnRunning = false
            replyIndex = nil
            if ev["is_error"] as? Bool == true, subtype != "error_during_execution" {
                messages.append(Message(role: .system, text: "⚠️ \(ev["result"] as? String ?? subtype ?? "error")"))
            }
            if !isVisible() {
                unread = true
                if !turnText.isEmpty { onReport(turnText, false) }
            }
            onTurnEnd()
            if contextTokens > cfg.compactAt ?? defaults.compactAt ?? 120_000 { compact() }
            restartIfIdle()
        default: break
        }
    }
}
