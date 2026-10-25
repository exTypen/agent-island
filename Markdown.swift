import SwiftUI

/// Block-level markdown (tables, lists, headings, code, quotes) for agent replies. Foundation's full parser tags every
/// run with its enclosing blocks (innermost first); runs are grouped into leaf blocks and table cells, then laid out.
struct MarkdownView: View {
    let text: String

    enum Block {
        case leaf(AttributedString, path: [PresentationIntent.Kind], marker: String?)
        case table([PresentationIntent.TableColumn], rows: [[AttributedString]])
    }

    static func blocks(_ text: String) -> [Block]? {
        guard let a = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full)) else { return nil }
        var out: [Block] = [], ids: [Int] = [] // ids: identity of the leaf block / table each output block came from
        var markedItems = Set<Int>()
        var cells: [Int: [Int: AttributedString]] = [:] // the table being collected: row -> column -> text
        for run in a.runs {
            var piece = AttributedString(a[run.range])
            if run.inlinePresentationIntent?.contains(.softBreak) == true { piece = AttributedString("\n") }
            let path = run.presentationIntent?.components ?? []
            if let table = path.first(where: { if case .table = $0.kind { return true }; return false }) {
                if ids.last != table.identity { out.append(.table([], rows: [])); ids.append(table.identity); cells = [:] }
                guard case .table(let columns) = table.kind else { continue }
                var row = 0, col = 0
                for c in path {
                    if case .tableRow(let r) = c.kind { row = r }
                    if case .tableCell(let i) = c.kind { col = i }
                }
                cells[row, default: [:]][col, default: AttributedString()] += piece
                let rows = cells.keys.sorted().map { r in columns.indices.map { cells[r]?[$0] ?? AttributedString() } }
                out[out.count - 1] = .table(columns, rows: rows)
            } else if let leaf = path.first, ids.last == leaf.identity, case .leaf(let s, let p, let m) = out.last {
                out[out.count - 1] = .leaf(s + piece, path: p, marker: m)
            } else {
                // A list item's marker goes on its first leaf only; nested leaves are indented under it.
                var marker: String?
                if let i = path.firstIndex(where: { if case .listItem = $0.kind { return true }; return false }),
                   markedItems.insert(path[i].identity).inserted, case .listItem(let n) = path[i].kind {
                    if i + 1 < path.count, case .orderedList = path[i + 1].kind { marker = "\(n)." } else { marker = "•" }
                }
                out.append(.leaf(piece, path: path.map(\.kind), marker: marker))
                ids.append(path.first?.identity ?? -1)
            }
        }
        return out
    }

    var body: some View {
        if let blocks = Self.blocks(text) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(blocks.indices, id: \.self) { i in
                    switch blocks[i] {
                    case .leaf(let s, let path, let marker): leaf(s, path: path, marker: marker)
                    case .table(let columns, let rows): table(columns, rows: rows)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
        }
    }

    @ViewBuilder func leaf(_ s: AttributedString, path: [PresentationIntent.Kind], marker: String?) -> some View {
        let depth = path.filter { if case .listItem = $0 { return true }; return false }.count
        let quoted = path.contains { if case .blockQuote = $0 { return true }; return false }
        let content: AnyView = {
            switch path.first {
            case .header(let level)?:
                return AnyView(Text(s).font(.system(size: [16, 14.5, 13.5][min(level, 3) - 1], weight: .semibold)))
            case .codeBlock?:
                var code = s
                if code.characters.last == "\n" { code.characters.removeLast() }
                return AnyView(Text(code).font(.system(size: 11.5, design: .monospaced))
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3))))
            case .thematicBreak?:
                return AnyView(Divider().padding(.vertical, 2))
            default:
                return AnyView(Text(s))
            }
        }()
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if depth > 0 {
                Text(marker ?? "").foregroundStyle(.secondary).frame(width: 14, alignment: .trailing)
            }
            content
        }
        .padding(.leading, CGFloat(max(depth - 1, 0)) * 16)
        .padding(.leading, quoted ? 9 : 0)
        .overlay(alignment: .leading) {
            if quoted { RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.5)).frame(width: 2) }
        }
        .foregroundStyle(quoted ? .secondary : .primary)
    }

    func table(_ columns: [PresentationIntent.TableColumn], rows: [[AttributedString]]) -> some View {
        // ponytail: columns of short cells keep their natural width so long ones get the room; a real width solver if this misjudges
        let narrow = columns.indices.map { c in rows.allSatisfy { $0[c].characters.count <= 14 } }
        return Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(rows.indices, id: \.self) { r in
                if r > 0 { Divider().opacity(r == 1 ? 0.8 : 0.35) }
                GridRow {
                    ForEach(rows[r].indices, id: \.self) { c in
                        Text(rows[r][c])
                            .fontWeight(r == 0 ? .semibold : nil)
                            .fixedSize(horizontal: narrow[c], vertical: true)
                            .gridColumnAlignment(columns[c].alignment == .center ? .center
                                : columns[c].alignment == .right ? .trailing : .leading)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12)))
    }
}
