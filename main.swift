import AppKit
import AVFoundation
import Combine
import Speech
import SwiftUI

// MARK: - Geometry

enum Side: String { case left, right, top, bottom }

/// Sizes are (along the edge, depth away from the edge).
let pillRest = CGSize(width: 92, height: 24)
let pillHover = CGSize(width: 108, height: 30)
let panelSize = CGSize(width: 380, height: 460) // screen width × height, every side
let flareMax: CGFloat = 10 // concave fillet where the island meets the screen edge
let pad: CGFloat = 24 // transparent room for the shadow

let morph = Animation.spring(duration: 0.5, bounce: 0.24)
let hoverSpring = Animation.spring(duration: 0.32, bounce: 0.4)

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // Let the window hang off-screen on the edge side; the island itself stays flush.
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r }
}

final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Model

final class Model: ObservableObject {
    @Published var expanded = false
    @Published var hovering = false
    @Published var dragging = false
    @Published var side: Side
    /// The island body in window-local SwiftUI coordinates (top-left origin). Animating this is the morph.
    @Published var shape = CGRect.zero
    @Published var input = ""
    @Published var recording = false
    @Published var agents: [Agent] = []
    @Published var selectedID: String?
    @Published var configError: String?
    @Published var level: Float = 0 // mic input level 0…1 while recording
    @Published var transcribing = false // Whisper is turning the recording into the final text
    var whisper: Whisper?
    private var vocabulary: [String] = []
    private var recordPrefix = ""
    /// Hands-free dictation (⌥⌥, the mic button) ends by itself when the user pauses; push-to-talk ends on release.
    enum AutoStop { case send, keep }
    private var autoStop: AutoStop?
    private var endOfSpeech = EndOfSpeech()
    private var lastLevelAt = Date()
    // Inbox
    @Published var reports: [Report] = []
    @Published var routeAsk: RouteAsk?
    @Published var cursor = 0
    @Published var inputFocused = false
    @Published var notice: String?
    var router: Router?
    /// Space held with an empty input = push-to-talk; release sends.
    var pttHeld = false
    private var pttStarted = Date.distantPast
    private var pttPoll: Timer?

    var along: CGFloat
    var screen = NSScreen.main ?? NSScreen.screens[0]
    weak var panel: NSPanel?

    private var dragOffset: CGPoint?
    private var speech = Speech()

    init() {
        side = Side(rawValue: UserDefaults.standard.string(forKey: "side") ?? "") ?? .right
        along = UserDefaults.standard.object(forKey: "along") as? CGFloat ?? 0.5
        loadAgents()
        watchConfig()
    }

    // MARK: agents

    /// nil while the Inbox is showing.
    var selected: Agent? { inInbox ? nil : agents.first { $0.id == selectedID } ?? agents.first }
    var anyBusy: Bool { agents.contains { $0.busy } }
    var anyUnread: Bool { agents.contains { $0.unread } }

    /// Applies agents.yaml to the running island: new agents are added, removed ones stopped, changed ones restart when
    /// idle (keeping their session). Nothing is torn down wholesale, so the manager agent can edit the file mid-turn.
    func loadAgents() {
        let cfg: Config
        do {
            cfg = try loadConfig()
        } catch {
            configError = "agents.yaml: \(error.localizedDescription)"
            manager?.messages.append(Message(role: .system, text: "⚠️ agents.yaml not applied: \(error.localizedDescription)"))
            return
        }
        configError = nil
        configStamp = Model.stamp()
        let defaults = cfg.defaults ?? Defaults()
        let sessions = Sessions.load()
        var next: [Agent] = [], added: [String] = [], changed: [String] = []
        for c in cfg.agents where !next.contains(where: { $0.id == c.id }) {
            if let a = agents.first(where: { $0.id == c.id }) {
                if a.cfg != c { changed.append(c.name) }
                a.update(c, defaults: defaults)
                next.append(a)
            } else {
                let a = Agent(c, defaults: defaults, session: sessions[c.id])
                wire(a)
                next.append(a)
                added.append(c.name)
            }
        }
        let removed = agents.filter { a in !next.contains { $0 === a } }
        removed.forEach { $0.stop(); subscriptions[$0.id] = nil }
        let firstLoad = agents.isEmpty
        withAnimation(.spring(duration: 0.4, bounce: 0.25)) {
            agents = next
            reports.removeAll { r in !next.contains { $0.id == r.agentID } }
        }
        vocabulary = voiceVocabulary(cfg)
        if !recording { speech = Speech(locale: defaults.voiceLocale, hints: vocabulary) }
        if cfg.voice?.whisper != whisper?.cfg, !recording, !transcribing {
            whisper?.stop()
            whisper = cfg.voice?.whisper.map(Whisper.init)
        }
        if cfg.router != router?.cfg {
            router?.stop()
            router = cfg.router.map(Router.init)
        }
        if !inInbox, !agents.contains(where: { $0.id == selectedID }) { selectedID = Model.inboxID }
        guard !firstLoad else { return }
        let summary = [("added", added), ("updated", changed), ("removed", removed.map(\.cfg.name))]
            .filter { !$0.1.isEmpty }.map { "\($0.0) \($0.1.joined(separator: ", "))" }.joined(separator: " · ")
        if !summary.isEmpty { manager?.messages.append(Message(role: .system, text: "agents.yaml applied · \(summary)")) }
    }

    /// The agent that edits agents.yaml for the user (`manager: true`, else the first one).
    var manager: Agent? { agents.first { $0.cfg.manager == true } ?? agents.first }

    private var subscriptions: [String: AnyCancellable] = [:]
    private var configStamp: Date?
    private var configWatch: Timer?

    private static func stamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
    }

    /// Polls the file's modification date: editors and agents often replace the file rather than write in place,
    /// which a file-descriptor watch would lose.
    func watchConfig() {
        configWatch = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, let s = Model.stamp(), s != self.configStamp else { return }
            self.loadAgents()
        }
    }

    private func wire(_ a: Agent) {
        a.isVisible = { [weak self, weak a] in self?.expanded == true && self?.selected === a }
        a.onTurnEnd = { [weak self] in self?.nudge() }
        a.onReport = { [weak self, weak a] text, failed in
            guard let self, let a else { return }
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                self.reports.insert(Report(agentID: a.id, text: text, failed: failed), at: 0)
                self.reports = Array(self.reports.prefix(50))
            }
        }
        // Re-render the island (chips, pill dot) whenever any agent changes.
        subscriptions[a.id] = a.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    func select(_ a: Agent) {
        withAnimation(.spring(duration: 0.3, bounce: 0.25)) {
            selectedID = a.id
            reports.removeAll { $0.agentID == a.id } // seen
        }
        a.unread = false
    }

    /// While closed, the island briefly swells when an agent finishes a turn.
    func nudge() {
        guard !expanded, !hovering, dragOffset == nil, let p = panel else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.5)) { shape = local(pillBody(hover: true), in: p.frame) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard !self.expanded, !self.hovering, self.dragOffset == nil else { return }
            withAnimation(hoverSpring) { self.shape = self.local(self.pillBody(hover: false), in: p.frame) }
        }
    }

    // MARK: layout

    var vertical: Bool { side == .left || side == .right }

    /// Screen rect of a body flush with the physical screen edge, positioned `along` it.
    private func body(_ size: CGSize) -> NSRect {
        let f = screen.frame, v = screen.visibleFrame
        var o = CGPoint.zero
        if vertical {
            o.x = side == .left ? f.minX : f.maxX - size.width
            o.y = min(max(v.minY + along * v.height - size.height / 2, v.minY), v.maxY - size.height)
        } else {
            o.y = side == .bottom ? f.minY : f.maxY - size.height
            o.x = min(max(v.minX + along * v.width - size.width / 2, v.minX), v.maxX - size.width)
        }
        return NSRect(origin: o, size: size)
    }

    func pillBody(hover: Bool) -> NSRect {
        let s = hover ? pillHover : pillRest
        return body(vertical ? CGSize(width: s.height, height: s.width) : s)
    }

    func panelBody() -> NSRect { body(panelSize) }

    /// The window never resizes for hover/expand: it already covers both states, so those are pure SwiftUI morphs.
    var container: NSRect {
        panelBody().union(pillBody(hover: true))
            .insetBy(dx: -pad - (vertical ? 0 : flareMax), dy: -pad - (vertical ? flareMax : 0))
    }

    func local(_ r: NSRect, in w: NSRect) -> CGRect {
        CGRect(x: r.minX - w.minX, y: w.maxY - r.maxY, width: r.width, height: r.height)
    }

    var shapeOnScreen: NSRect {
        guard let w = panel?.frame else { return .zero }
        return NSRect(x: w.minX + shape.minX, y: w.maxY - shape.maxY, width: shape.width, height: shape.height)
    }

    func place() {
        guard let p = panel else { return }
        p.setFrame(container, display: true)
        shape = local(expanded ? panelBody() : pillBody(hover: hovering), in: container)
    }

    // MARK: open / close / hover

    func open() {
        guard !expanded, let p = panel else { return }
        if anyNeedsInput { showInbox() }
        router?.warm() // load the decision model while the user types
        selected?.unread = false
        withAnimation(morph) {
            expanded = true
            hovering = false
            shape = local(panelBody(), in: p.frame)
        }
        p.ignoresMouseEvents = false
        p.makeKey()
    }

    func close() {
        guard expanded, let p = panel else { return }
        router?.panelClosed()
        whisper?.service.panelClosed()
        if recording { toggleMic() }
        withAnimation(.spring(duration: 0.42, bounce: 0.16)) {
            expanded = false
            shape = local(pillBody(hover: false), in: p.frame)
        }
        trackMouse()
    }

    /// Fed by global + local mouse monitors. Only the island itself takes clicks; the rest of the window is click-through.
    func trackMouse() {
        guard let p = panel, dragOffset == nil else { return }
        let inside = shapeOnScreen.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
        p.ignoresMouseEvents = !inside
        if !expanded, inside != hovering {
            withAnimation(hoverSpring) {
                hovering = inside
                shape = local(pillBody(hover: inside), in: p.frame)
            }
        }
    }

    // MARK: drag + snap

    func dragMoved() {
        guard let p = panel, !expanded else { return }
        let m = NSEvent.mouseLocation
        if dragOffset == nil {
            dragOffset = CGPoint(x: m.x - p.frame.minX, y: m.y - p.frame.minY)
            withAnimation(.spring(duration: 0.3, bounce: 0.35)) {
                dragging = true
                hovering = false
                shape = local(pillBody(hover: false), in: p.frame)
            }
        }
        p.setFrameOrigin(CGPoint(x: m.x - dragOffset!.x, y: m.y - dragOffset!.y))
    }

    func dragEnded() {
        guard let p = panel, dragOffset != nil else { return }
        dragOffset = nil
        let s = shapeOnScreen, c = NSPoint(x: s.midX, y: s.midY)
        screen = NSScreen.screens.first { NSMouseInRect(c, $0.frame, false) } ?? screen
        let f = screen.frame, v = screen.visibleFrame
        let dist: [(Side, CGFloat)] = [
            (.left, c.x - f.minX), (.right, f.maxX - c.x), (.bottom, c.y - f.minY), (.top, f.maxY - c.y),
        ]
        side = dist.min { $0.1 < $1.1 }!.0
        along = min(max(vertical ? (c.y - v.minY) / v.height : (c.x - v.minX) / v.width, 0), 1)
        UserDefaults.standard.set(side.rawValue, forKey: "side")
        UserDefaults.standard.set(Double(along), forKey: "along")

        // Window glides (AppKit) while the body re-docks inside it (SwiftUI) on the same curve.
        let target = container, dur = 0.5
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = dur
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            p.animator().setFrame(target, display: true)
        }
        withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: dur)) {
            dragging = false
            shape = local(pillBody(hover: false), in: target)
        }
    }

    func send() {
        if recording { return toggleMic(then: { [weak self] in self?.send() }) }
        guard !transcribing else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        if let a = selected { a.send(text) } else { submitInInbox(text) }
    }

    // MARK: voice

    /// Starts or stops dictation. While talking, Apple's recognizer fills the field live; on stop, local Whisper (when
    /// configured) replaces that with its own transcript. `then` runs once the final text is in the field.
    func toggleMic(then: (() -> Void)? = nil, discard: Bool = false, autoStop: AutoStop? = nil) {
        if recording {
            self.autoStop = nil
            let audio = speech.stop()
            withAnimation(.easeOut(duration: 0.2)) { recording = false; level = 0 }
            guard let whisper, !discard, audio.count > 16000 / 2 else {
                whisper?.cancel()
                // Apple's recognizer delivers its final words just after endAudio.
                if let then { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: then) }
                return
            }
            withAnimation(.easeOut(duration: 0.2)) { transcribing = true }
            let prefix = recordPrefix
            whisper.transcribe(audio, hotwords: vocabulary) { [weak self] text in
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.2)) { self.transcribing = false }
                if let text, !text.isEmpty { self.input = prefix + text } // else keep Apple's text
                then?()
            }
        } else {
            recordPrefix = input.isEmpty ? "" : input + " "
            let prefix = recordPrefix
            withAnimation(.spring(duration: 0.3, bounce: 0.3)) { recording = true }
            self.autoStop = autoStop
            endOfSpeech = EndOfSpeech()
            lastLevelAt = Date()
            whisper?.warm() // loads while the user talks
            speech.start(level: { [weak self] l in self?.heard(l) }) { [weak self] text, error in
                // Apple sends its last words just after stop; with Whisper they'd only race its transcript.
                guard let self, self.recording || self.whisper == nil else { return }
                if let error {
                    self.speech.stop()
                    self.whisper?.cancel()
                    self.recording = false
                    self.selected?.messages.append(Message(role: .system, text: "🎙 \(error)"))
                } else {
                    self.input = prefix + text
                }
            }
        }
    }

    private func heard(_ l: Float) {
        level = l
        let now = Date()
        defer { lastLevelAt = now }
        guard recording, let mode = autoStop, !pttHeld else { return }
        switch endOfSpeech.feed(l, dt: now.timeIntervalSince(lastLevelAt)) {
        case .listening: break
        case .done: toggleMic(then: mode == .send ? { [weak self] in self?.send() } : nil)
        case .nothingSaid: toggleMic(discard: true)
        }
    }

    func pushToTalk(down: Bool) {
        if down {
            pttHeld = true
            pttStarted = Date()
            if !recording { toggleMic() }
            // A permission prompt can steal key focus mid-hold and swallow the keyUp; ask the hardware instead.
            pttPoll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                if !CGEventSource.keyState(.combinedSessionState, key: 49) { self?.pushToTalk(down: false) }
            }
        } else {
            guard pttHeld else { return }
            pttHeld = false
            pttPoll?.invalidate()
            guard recording else { return }
            if Date().timeIntervalSince(pttStarted) < 0.3 { // a tap, not a hold
                toggleMic(discard: true)
                input = ""
                return
            }
            toggleMic(then: { [weak self] in self?.send() })
        }
    }
}

// MARK: - Views

let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

/// Notch-style body: flat against the screen edge with concave fillets into it, rounded on the outside.
struct IslandShape: Shape {
    var side: Side
    var edge: CGFloat // < 0: concave flare into the edge, > 0: convex corner (floating while dragged)
    var outer: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(edge, outer) }
        set { edge = newValue.first; outer = newValue.second }
    }

    /// `rect` includes `flareMax` on both ends along the edge.
    func path(in rect: CGRect) -> Path {
        let vertical = side == .left || side == .right
        let len = vertical ? rect.height : rect.width, depth = vertical ? rect.width : rect.height
        // (u along the edge, v away from it) → view space
        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            switch side {
            case .top: CGPoint(x: rect.minX + u, y: rect.minY + v)
            case .bottom: CGPoint(x: rect.minX + u, y: rect.maxY - v)
            case .left: CGPoint(x: rect.minX + v, y: rect.minY + u)
            case .right: CGPoint(x: rect.maxX - v, y: rect.minY + u)
            }
        }
        let a = flareMax, b = len - flareMax
        let k = min(abs(edge), edge < 0 ? flareMax : depth / 2, (b - a) / 2)
        let r = max(min(outer, depth - k, (b - a) / 2), 0)
        let start = edge < 0 ? a - k : a + k
        var p = Path()
        p.move(to: pt(start, 0))
        p.addArc(tangent1End: pt(a, 0), tangent2End: pt(a, depth), radius: k)
        p.addArc(tangent1End: pt(a, depth), tangent2End: pt(b, depth), radius: r)
        p.addArc(tangent1End: pt(b, depth), tangent2End: pt(b, 0), radius: r)
        p.addArc(tangent1End: pt(b, 0), tangent2End: pt(len - start, 0), radius: k)
        p.closeSubpath()
        return p
    }
}

struct RootView: View {
    @ObservedObject var m: Model
    @State private var pulse = false

    var body: some View {
        let sh = m.shape
        let depth = m.vertical ? sh.width : sh.height
        let edge: CGFloat = m.dragging ? depth / 2 : m.expanded ? -flareMax : -6
        let outer: CGFloat = m.dragging || !m.expanded ? depth / 2 : 26
        let drawn = m.vertical ? sh.insetBy(dx: 0, dy: -flareMax) : sh.insetBy(dx: -flareMax, dy: 0)
        let panel = m.local(m.panelBody(), in: m.panel?.frame ?? .zero)
        let anchor: UnitPoint = switch m.side {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }

        ZStack(alignment: .topLeading) {
            IslandShape(side: m.side, edge: edge, outer: outer)
                .fill(Color.black)
                .shadow(color: .black.opacity(m.expanded ? 0.45 : m.dragging ? 0.4 : 0.2),
                        radius: m.expanded ? 18 : m.dragging ? 12 : 4)
                .frame(width: drawn.width, height: drawn.height)
                .offset(x: drawn.minX, y: drawn.minY)

            if m.expanded {
                ExpandedView(m: m)
                    // Clear the menu bar / notch when hanging from the top edge.
                    .padding(.top, m.side == .top ? m.screen.frame.maxY - m.screen.visibleFrame.maxY : 0)
                    .frame(width: panel.width, height: panel.height)
                    // Clip to the live (animating) island so content never spills past the morph.
                    .mask(alignment: .topLeading) {
                        IslandShape(side: m.side, edge: edge, outer: outer)
                            .frame(width: drawn.width, height: drawn.height)
                            .offset(x: drawn.minX - panel.minX, y: drawn.minY - panel.minY)
                    }
                    .offset(x: panel.minX, y: panel.minY)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: anchor))
                            .animation(.easeOut(duration: 0.26).delay(0.12)),
                        removal: .opacity.animation(.easeIn(duration: 0.1))))
            } else {
                Circle()
                    .fill(m.recording ? Color.red : m.anyNeedsInput ? amber : m.anyBusy ? Color.blue : m.anyUnread ? Color.green : Color.white.opacity(0.55))
                    .frame(width: 7, height: 7)
                    .scaleEffect(m.hovering ? 1.3 : 1)
                    .shadow(color: m.anyNeedsInput ? amber : m.anyBusy ? .blue : m.anyUnread ? .green : .clear, radius: m.hovering ? 6 : 3)
                    .opacity(m.anyBusy ? (pulse ? 1 : 0.3) : 1)
                    .animation(m.anyBusy ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
                    .frame(width: sh.width, height: sh.height)
                    .contentShape(Rectangle())
                    .offset(x: sh.minX, y: sh.minY)
                    .onTapGesture { m.open() }
                    .gesture(
                        DragGesture(minimumDistance: 3, coordinateSpace: .global)
                            .onChanged { _ in m.dragMoved() }
                            .onEnded { _ in m.dragEnded() }
                    )
                    .contextMenu {
                        if !AXIsProcessTrusted() {
                            Button("Enable ⌥⌥ shortcut…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                        }
                        Button("Edit agents.yaml") { NSWorkspace.shared.open(configURL) }
                        Button("Reload agents") { m.loadAgents() }
                        Divider()
                        Button("Quit Agent Island") { NSApp.terminate(nil) }
                    }
                    .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.15)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { pulse = true }
    }
}

struct ExpandedView: View {
    @ObservedObject var m: Model
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        InboxChip(m: m)
                        ForEach(m.agents) { a in Chip(agent: a, selected: a === m.selected) { m.select(a) } }
                    }
                }
                if let a = m.selected {
                    if a.contextTokens > 0 {
                        Button { a.compact() } label: {
                            Text("\(a.contextTokens / 1000)k").font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help("Context size · click to /compact")
                    }
                    Button { a.newSession() } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.plain).help("New session for \(a.cfg.name)")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)

            if let a = m.selected { TaskStrip(agent: a) }
            Divider().opacity(0.3)

            if let err = m.configError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red).padding(14)
                Spacer()
            } else if let a = m.selected {
                // A distinct view per agent: switching tabs swaps conversations instead of morphing one into the other.
                Conversation(agent: a, m: m).id(a.id).transition(.opacity)
            } else {
                InboxView(m: m)
            }

            if let n = m.notice {
                Text(n).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 8) {
                TextField(placeholder, text: $m.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit { m.send() }
                    .onExitCommand { m.close() }
                    // Live text is provisional while Whisper is going to replace it.
                    .opacity(m.whisper != nil && (m.recording || m.transcribing) ? 0.55 : 1)
                    .animation(.easeOut(duration: 0.2), value: m.transcribing)
                if m.transcribing {
                    ProgressView().controlSize(.small).help("Transcribing with Whisper")
                        .transition(.scale.combined(with: .opacity))
                }
                if m.recording { LevelBars(level: m.level).transition(.scale.combined(with: .opacity)) }
                Button { m.recording ? m.toggleMic() : m.toggleMic(autoStop: .keep) } label: {
                    Image(systemName: m.recording ? "stop.circle.fill" : "mic.fill")
                        .foregroundStyle(m.recording ? .red : .primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain).help("Dictate · or hold Space with an empty field")
                if m.selected?.turnRunning == true && m.input.isEmpty {
                    Button { m.selected?.interrupt() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.plain).help("Interrupt (subagents keep running)")
                } else {
                    Button { m.send() } label: {
                        Image(systemName: "arrow.up.circle.fill").foregroundStyle(m.selected?.color ?? .white)
                    }
                    .buttonStyle(.plain).disabled(m.input.isEmpty)
                }
            }
            .font(.system(size: 15))
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(m.recording ? 0.6 : 0)))
            .padding(10)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // The panel becomes key right after this view appears; focusing earlier is dropped.
        // In a non-empty Inbox the card list keeps the keys (J/K/1–9), so the field stays unfocused.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { m.inputFocused = wantsField } }
        .onChange(of: m.selectedID) { m.inputFocused = wantsField }
        // A new card that wants an answer takes the keys, unless the user is mid-sentence.
        .onChange(of: m.cards.count) { old, new in
            if new > old, m.inInbox, m.input.isEmpty, m.currentCard?.needsInput == true { m.inputFocused = false }
        }
        .onChange(of: m.inputFocused) { focused = m.inputFocused }
        .onChange(of: focused) { m.inputFocused = focused }
    }

    private var wantsField: Bool { !(m.inInbox && !m.cards.isEmpty) }

    private var placeholder: String {
        if m.recording { return m.pttHeld ? "Listening…" : "Listening… pause to finish" }
        if let a = m.selected { return "Message \(a.cfg.name)" }
        if case .ask(let a, let p)? = m.currentCard { return p.isQuestion ? "Answer \(a.cfg.name)…" : "Tell \(a.cfg.name) what to do instead…" }
        return "Message — routed to the right agent"
    }
}

struct LevelBars: View {
    let level: Float
    private let weights: [Float] = [0.55, 0.85, 1, 0.75, 0.5]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule().fill(Color.red)
                    .frame(width: 3, height: 4 + CGFloat(level * weights[i]) * 14)
            }
        }
        .frame(height: 18)
        .animation(.spring(duration: 0.15, bounce: 0.2), value: level)
    }
}

struct Chip: View {
    @ObservedObject var agent: Agent
    let selected: Bool
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(agent.needsInput ? amber : agent.color).frame(width: 7, height: 7)
                    .opacity(agent.busy && !agent.needsInput ? (pulse ? 1 : 0.3) : 1)
                    .animation(agent.busy ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
                Text(agent.cfg.name).font(.system(size: 12, weight: selected ? .semibold : .regular))
                if agent.unread && !selected { Circle().fill(Color.green).frame(width: 5, height: 5) }
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(selected ? agent.color.opacity(0.28) : Color.white.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: selected)
        .onAppear { pulse = true }
        .help(agent.cfg.role ?? agent.cfg.dir)
    }
}

/// Live view of what the orchestrator has in flight: its subagents and background jobs.
struct TaskStrip: View {
    @ObservedObject var agent: Agent

    var body: some View {
        if !agent.tasks.isEmpty || agent.status != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let st = agent.status {
                    Label(st, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                }
                ForEach(agent.tasks) { t in
                    HStack(spacing: 6) {
                        switch t.state {
                        case "running": ProgressView().controlSize(.mini)
                        case "completed": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        default: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                        Text(t.title).lineLimit(1)
                        if let d = t.detail, t.state == "running", d != t.title {
                            Text(d).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 14).padding(.bottom, 8)
            .animation(.spring(duration: 0.35, bounce: 0.2), value: agent.tasks.map(\.state))
        }
    }
}

struct Conversation: View {
    @ObservedObject var agent: Agent
    @ObservedObject var m: Model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if agent.messages.isEmpty {
                        Text("\(agent.cfg.name) · \(agent.cfg.dir)\nAsk for several things at once; \(agent.cfg.name) runs them in parallel. Type, or hit 🎙 and talk.")
                            .foregroundStyle(.secondary).font(.system(size: 12))
                    }
                    ForEach(agent.messages) { msg in
                        Bubble(msg: msg, tint: agent.color).id(msg.id)
                    }
                    if agent.turnRunning && agent.messages.last?.role != .assistant && agent.pending.isEmpty {
                        Text("…").foregroundStyle(.secondary).id("typing")
                    }
                    ForEach(agent.pending) { p in
                        CardView(card: .ask(agent, p), m: m).id(p.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: agent.messages.last?.text) {
                if let id = agent.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onChange(of: agent.pending.count) {
                if let p = agent.pending.last { withAnimation { proxy.scrollTo(p.id, anchor: .bottom) } }
            }
            .onAppear { if let id = agent.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
        }
    }
}

struct Bubble: View {
    let msg: Message
    let tint: Color

    var body: some View {
        let md = (try? AttributedString(
            markdown: msg.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(msg.text)
        if msg.role == .system {
            Text(md).font(.system(size: 10.5)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else {
            HStack {
                if msg.role == .user { Spacer(minLength: 40) }
                Text(md)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(msg.role == .user ? tint.opacity(0.35) : Color.white.opacity(0.07)))
                if msg.role == .assistant { Spacer(minLength: 0) }
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var panel: IslandPanel!

    func applicationDidFinishLaunching(_ n: Notification) {
        signal(SIGPIPE, SIG_IGN) // a dead claude process must not take the app down on write
        panel = IslandPanel(
            contentRect: model.container,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI draws it, so it follows the morph
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentView = FirstMouseHostingView(rootView: RootView(m: model))
        model.panel = panel
        model.place()
        panel.orderFrontRegardless()

        let m = model
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in m.trackMouse() }
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { m.trackMouse(); return $0 }
        // A click that reaches another app is by definition outside the island.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in m.close() }

        // Double-tap Option → open and start dictating. Global monitor needs Accessibility permission.
        var lastOption = Date.distantPast
        let onFlags: (NSEvent) -> Void = { [weak self] e in
            guard let m = self?.model, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option else { return }
            if Date().timeIntervalSince(lastOption) < 0.35 {
                lastOption = .distantPast
                m.open()
                if !m.recording { m.toggleMic(autoStop: .send) } // hands-free: ends and sends when you pause
            } else {
                lastOption = Date()
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: onFlags)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { onFlags($0); return $0 }

        // Panel shortcuts: hold Space (empty field) to talk, ⌘1…9 to switch agent.
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            guard m.expanded else { return e }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.type == .keyDown, mods == .command, let n = Int(e.charactersIgnoringModifiers ?? ""),
               (1...m.agents.count + 1).contains(n) {
                if n == 1 { m.showInbox() } else { m.select(m.agents[n - 2]) }
                return nil
            }
            if e.type == .keyDown, m.inInbox, let handled = inboxKey(e, mods) { return handled ? nil : e }
            guard e.keyCode == 49, mods.isEmpty else { return e } // Space
            if e.type == .keyDown {
                if m.pttHeld { return nil } // key repeat while held
                guard m.input.isEmpty, !e.isARepeat else { return e }
                m.pushToTalk(down: true)
                return nil
            }
            guard m.pttHeld else { return e }
            m.pushToTalk(down: false)
            return nil
        }
        // The system Accessibility dialog shows at most once ever; after that the island's menu offers it.
        if !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: "askedAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            m.router?.stop()
            m.whisper?.stop()
            m.agents.forEach { $0.stop() }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let m = self?.model else { return }
            if !NSScreen.screens.contains(m.screen) { m.screen = NSScreen.main ?? NSScreen.screens[0] }
            m.place()
        }
    }
}

/// Inbox keyboard: the card list owns plain keys while the text field isn't focused.
/// Returns true = consumed, false = pass through, nil = not an Inbox key.
func inboxKey(_ e: NSEvent, _ mods: NSEvent.ModifierFlags) -> Bool? {
    let m = delegate.model
    guard mods.subtracting([.function, .numericPad]).isEmpty else { return nil }
    let code = e.keyCode, chars = e.charactersIgnoringModifiers ?? ""
    if m.inputFocused {
        switch code {
        case 48: m.inputFocused = false; return true // Tab → list
        case 125 where m.input.isEmpty: m.moveCursor(1); return true // ↓
        case 126 where m.input.isEmpty: m.moveCursor(-1); return true // ↑
        default: return nil
        }
    }
    // With no cards there's nothing to navigate: every key is typing.
    if m.cards.isEmpty, code != 53, code != 49 {
        m.inputFocused = true
        if let c = e.characters, !c.isEmpty, c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            m.input += c
        }
        return true
    }
    let card = m.currentCard
    switch code {
    case 38, 125: m.moveCursor(1) // J ↓
    case 40, 126: m.moveCursor(-1) // K ↑
    case 14: if let card { m.clear(card) } // E
    case 36, 76: if let card { m.confirm(card) } // ↵
    case 53: m.close() // Esc
    case 48: m.inputFocused = true // Tab
    case 49: return nil // Space: push-to-talk handles it
    default:
        if let d = Int(chars), (1...9).contains(d) {
            if let card { m.act(card, option: d - 1) }
        } else if !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            // Any other typing starts a message.
            m.input += e.characters ?? chars
            m.inputFocused = true
        } else {
            return nil
        }
    }
    return true
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
