// Check MarkdownView's block grouping (Markdown.swift) and render a sample reply to /tmp/markdown.png. Run from the repo root:
//   swiftc -parse-as-library -o /tmp/md tests/markdown_view.swift Markdown.swift && /tmp/md
import SwiftUI

let sample = """
**Seçenekler**

| | Yöntem | Sipariş tutarı doğru mu? | Efor |
|---|---|---|---|
| A | Sipariş oluşunca xt-sync Worker tutarı **%5** düşürür | Evet, birkaç saniye sonra | 2–3 gün |
| B | Hazır uygulama (PaySelect veya BTD, ~5$/ay) | Evet, ilk andan itibaren | Yarım gün |
| C | Teşekkür sayfasında sadece `×0,95` tutarını göster | Hayır | 1 gün |

**Önerim A.** Müşteri havaleyi bugünkü gibi seçer.
Ayrıca taksit vade farkı mekanizmasının aynısı.
- **A'nın riski:** Shopify ödemesi bekleyen siparişlerde
  - iç içe madde
- ikinci madde

1. bir
2. iki

> alıntı

## Başlık

```swift
let x = 1
```
"""

@main enum MarkdownCheck {
    static func main() { MainActor.assumeIsolated { run() } }
    @MainActor static func run() {
        var failed = false
        func check(_ ok: Bool, _ name: String) { print(ok ? "ok   \(name)" : "FAIL \(name)"); failed = failed || !ok }
        let blocks = MarkdownView.blocks(sample)!
        let tables = blocks.compactMap { if case .table(let c, let rows) = $0 { return (c, rows) }; return nil }
        check(tables.count == 1, "one table")
        check(tables.first?.1.count == 4 && tables.first?.1.allSatisfy { $0.count == 4 } == true, "table is 4x4")
        check(tables.first.map { String($0.1[1][1].characters) } == "Sipariş oluşunca xt-sync Worker tutarı %5 düşürür", "cell keeps inline runs")
        let leaves = blocks.compactMap { if case .leaf(let s, _, let m) = $0 { return (String(s.characters), m) }; return nil }
        check(leaves.contains { $0.0 == "Önerim A. Müşteri havaleyi bugünkü gibi seçer.\nAyrıca taksit vade farkı mekanizmasının aynısı." }, "soft break kept as newline")
        check(leaves.filter { $0.1 == "•" }.count == 3, "bullets incl. nested")
        check(leaves.contains { $0.0 == "iki" && $0.1 == "2." }, "ordered marker")

        let view = MarkdownView(text: sample).font(.system(size: 12.5)).foregroundStyle(.white)
            .padding(10).frame(width: 340).background(Color(white: 0.12)).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view); r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/markdown.png")); print("wrote /tmp/markdown.png")
        }
        exit(failed ? 1 : 0)
    }
}
