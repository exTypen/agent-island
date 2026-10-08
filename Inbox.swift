import SwiftUI

// MARK: - Model

/// A finished turn or a failure that happened while the user was looking elsewhere.
struct Report: Identifiable {
    let id = UUID()
    let agentID: String
    let text: String
    let failed: Bool
    let date = Date()
}

/// A message the router wasn't sure about: the user picks the agent.
struct RouteAsk: Identifiable {
    let id = UUID()
    let text: String
    var images: [Attachment] = []
    let ranked: [(id: String, p: Double)]
}

enum Card: Identifiable {
    case route(RouteAsk)
    case ask(Agent, Pending)
    case report(Report)

    var id: String {
        switch self {
        case .route(let r): "route-\(r.id)"
        case .ask(_, let p): "ask-\(p.id)"
        case .report(let r): "report-\(r.id)"
        }
    }

    var needsInput: Bool { if case .report = self { false } else { true } }
}

extension Model {
    static let inboxID = "_inbox"

    var inInbox: Bool { selectedID == Model.inboxID }

    /// Blocking things first (oldest first), then reports (newest first).
    var cards: [Card] {
        var c: [Card] = routeAsk.map { [.route($0)] } ?? []
        c += agents.flatMap { a in a.pending.map { (a, $0) } }.sorted { $0.1.date < $1.1.date }.map { Card.ask($0.0, $0.1) }
        return c + reports.map { .report($0) }
    }

    var anyNeedsInput: Bool { routeAsk != nil || agents.contains { $0.needsInput } }

    var currentCard: Card? {
        let c = cards
        return c.isEmpty ? nil : c[min(cursor, c.count - 1)]
    }

    func agent(_ id: String) -> Agent? { agents.first { $0.id == id } }

    func showInbox() {
        withAnimation(.spring(duration: 0.3, bounce: 0.25)) { selectedID = Model.inboxID }
        cursor = 0
    }

    func moveCursor(_ d: Int) {
        let n = cards.count
        guard n > 0 else { return }
        withAnimation(.spring(duration: 0.25, bounce: 0.2)) { cursor = max(0, min(n - 1, cursor + d)) }
    }

    func clear(_ card: Card) {
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
            switch card {
            case .report(let r): reports.removeAll { $0.id == r.id }
            case .route: routeAsk = nil
            case .ask: return // a blocked agent needs an answer, not a dismissal
            }
            cursor = min(cursor, max(cards.count - 1, 0))
        }
    }

    /// Option `i` (0-based; key i+1) on a card.
    func act(_ card: Card, option i: Int) {
        switch card {
        case .route(let r):
            guard r.ranked.indices.contains(i) else { return }
            withAnimation(.spring(duration: 0.3)) { routeAsk = nil }
            dispatch(r.text, to: r.ranked[i].id, images: r.images)
        case .ask(let a, let p):
            if p.isQuestion { a.answer(p, option: i) }
            else if i == 0 { a.respond(p, allow: true) }
            else if i == 1, !p.suggestions.isEmpty { a.respond(p, allow: true, always: true) }
            else if i == 2 || (i == 1 && p.suggestions.isEmpty) { a.respond(p, allow: false) }
        case .report(let r):
            if let a = agent(r.agentID) { select(a) }
        }
        cursor = min(cursor, max(cards.count - 1, 0))
    }

    /// Return on a card: open a report, take the router's best guess, allow a permission.
    func confirm(_ card: Card) {
        switch card {
        case .report, .route: act(card, option: 0)
        case .ask(_, let p): if !p.isQuestion { act(card, option: 0) }
        }
    }

    /// Text typed (or spoken) in the Inbox: answers the selected card if it's a question, else gets routed.
    func submitInInbox(_ text: String, images: [Attachment] = []) {
        if images.isEmpty, case .ask(let a, let p)? = currentCard {
            if p.isQuestion { a.answer(p, text: text) } else { a.respond(p, allow: false, message: text) }
            return
        }
        route(text, images: images)
    }

    func route(_ text: String, images: [Attachment] = []) {
        if agents.count == 1, let only = agents.first { return dispatch(text, to: only.id, images: images) }
        guard let router else {
            withAnimation(.spring(duration: 0.35)) { routeAsk = RouteAsk(text: text, images: images, ranked: agents.map { ($0.id, 0) }) }
            return
        }
        flash(router.isReady ? "routing…" : "waking the router…")
        router.route(text, agents.map(\.cfg)) { [weak self] d in
            guard let self else { return }
            if let id = d.agent {
                self.dispatch(text, to: id, p: d.ranked.first?.p, images: images)
            } else {
                withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                    self.routeAsk = RouteAsk(text: text, images: images, ranked: d.ranked)
                    self.cursor = 0
                    self.notice = nil
                }
                self.inputFocused = false // so 1/2/3 pick right away
            }
        }
    }

    func dispatch(_ text: String, to id: String, p: Double? = nil, images: [Attachment] = []) {
        guard let a = agent(id) else { return }
        a.send(text, images: images)
        flash("→ \(a.cfg.name)" + (p.map { String(format: " · %.0f%%", $0 * 100) } ?? ""))
    }

    func flash(_ s: String) {
        withAnimation(.easeOut(duration: 0.2)) { notice = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.notice == s { withAnimation(.easeIn(duration: 0.3)) { self.notice = nil } }
        }
    }
}

// MARK: - Views

let amber = Color(red: 0.98, green: 0.72, blue: 0.2)

struct InboxView: View {
    @ObservedObject var m: Model

    var body: some View {
        let cards = m.cards
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if cards.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Nothing waiting on you.").font(.system(size: 12, weight: .medium))
                            Text("Type or hold Space and talk — the router hands it to the right agent. Start with @name to address one directly.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.top, 6)
                    }
                    ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                        CardView(card: card, m: m, selected: i == m.cursor && !m.inputFocused)
                            .id(card.id)
                            .onTapGesture { m.cursor = i; m.inputFocused = false }
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .scale(scale: 0.9).combined(with: .opacity)))
                    }
                    if !cards.isEmpty {
                        Text("J/K move · 1–9 pick · ↵ open/allow · E clear · Tab to type")
                            .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 2)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: m.cursor) { if let c = m.currentCard { withAnimation { proxy.scrollTo(c.id, anchor: .center) } } }
        }
    }
}

struct CardView: View {
    let card: Card
    @ObservedObject var m: Model
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(selected ? 0.1 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
            selected ? Color.white.opacity(0.5) : card.needsInput ? amber.opacity(0.45) : .clear, lineWidth: 1))
        .scaleEffect(selected ? 1 : 0.985)
        .animation(.spring(duration: 0.25, bounce: 0.3), value: selected)
    }

    private var who: (name: String, color: Color) {
        switch card {
        case .route: ("Router", .white)
        case .ask(let a, _): (a.cfg.name, a.color)
        case .report(let r): (m.agent(r.agentID)?.cfg.name ?? r.agentID, m.agent(r.agentID)?.color ?? .white)
        }
    }

    private var kind: (String, Color) {
        switch card {
        case .route: ("who should take this?", amber)
        case .ask(_, let p): (p.isQuestion ? "asks" : "needs permission", amber)
        case .report(let r): (r.failed ? "failed" : "done", r.failed ? .red : .green)
        }
    }

    private var date: Date {
        switch card {
        case .route: Date()
        case .ask(_, let p): p.date
        case .report(let r): r.date
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(who.color).frame(width: 7, height: 7)
            Text(who.name).font(.system(size: 11.5, weight: .semibold))
            Text(kind.0).font(.system(size: 11)).foregroundStyle(kind.1)
            Spacer()
            Text(date, style: .relative).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var content: some View {
        switch card {
        case .route(let r):
            Text("“\(r.text)”").font(.system(size: 12)).lineLimit(3)
            ForEach(Array(r.ranked.enumerated()), id: \.offset) { i, e in
                OptionRow(n: i + 1, label: m.agent(e.id)?.cfg.name ?? e.id,
                          detail: e.p > 0 ? String(format: "%.0f%%", e.p * 100) : nil) { m.act(card, option: i) }
            }
        case .ask(_, let p):
            if let q = p.current {
                if let h = q.header { Text(h.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary) }
                Text(q.text).font(.system(size: 12.5, weight: .medium))
                ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in
                    OptionRow(n: i + 1, label: o.label, detail: o.detail) { m.act(card, option: i) }
                }
                Text("or type your own answer").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                Text(p.tool).font(.system(size: 12, weight: .medium))
                if !p.summary.isEmpty {
                    Text(p.summary).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4)
                }
                HStack(spacing: 6) {
                    KeyButton(n: 1, label: "Allow", tint: .green) { m.act(card, option: 0) }
                    if !p.suggestions.isEmpty { KeyButton(n: 2, label: "Always", tint: .green) { m.act(card, option: 1) } }
                    KeyButton(n: p.suggestions.isEmpty ? 2 : 3, label: "Deny", tint: .red) {
                        m.act(card, option: p.suggestions.isEmpty ? 1 : 2)
                    }
                }
                Text("or type what to do instead").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        case .report(let r):
            Text((try? AttributedString(markdown: r.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(r.text))
                .font(.system(size: 12)).lineLimit(5)
            Text("↵ open conversation").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

struct OptionRow: View {
    let n: Int
    let label: String
    let detail: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(n)").font(.system(size: 10, weight: .bold, design: .monospaced))
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 12))
                    if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct KeyButton: View {
    let n: Int
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("\(n)").font(.system(size: 10, weight: .bold, design: .monospaced)).opacity(0.7)
                Text(label).font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }
}

struct InboxChip: View {
    @ObservedObject var m: Model

    var body: some View {
        let n = m.cards.count
        Button { m.showInbox() } label: {
            HStack(spacing: 5) {
                Image(systemName: "tray.full").font(.system(size: 10.5))
                Text("Inbox").font(.system(size: 12, weight: m.inInbox ? .semibold : .regular))
                if n > 0 {
                    Text("\(n)").font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(m.anyNeedsInput ? amber : Color.white.opacity(0.25)))
                        .foregroundStyle(m.anyNeedsInput ? .black : .white)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(m.inInbox ? Color.white.opacity(0.18) : Color.white.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: n)
        .help("Inbox · ⌘1")
    }
}
