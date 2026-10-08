import AppKit
import UniformTypeIdentifiers

/// An image going out with the next message, already in the form Claude takes it (base64 PNG or JPEG).
struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let mediaType: String // image/png | image/jpeg

    /// Claude reads images up to ~1568 px on the long side; larger ones only cost tokens and upload time.
    static let maxSide: CGFloat = 1568

    init?(image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, Attachment.maxSide / max(w, h))
        let size = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cg, size: size).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        // Screenshots and UI compress best as PNG; photos as JPEG. Keep PNG unless it gets big.
        if let png = rep.representation(using: .png, properties: [:]), png.count < 1_500_000 {
            data = png
            mediaType = "image/png"
        } else if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            data = jpg
            mediaType = "image/jpeg"
        } else {
            return nil
        }
    }

    init?(url: URL) {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
              let image = NSImage(contentsOf: url) else { return nil }
        self.init(image: image)
    }

    var image: NSImage? { NSImage(data: data) }

    /// The Anthropic content block for this image.
    var block: [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]]
    }

    /// Images on the pasteboard: copied image files (Finder), or image data with no text alongside (screenshots,
    /// "Copy Image"). When text is there too, the paste is a text paste.
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> [Attachment] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let files = urls.compactMap(Attachment.init(url:))
        if !files.isEmpty { return files }
        guard pb.string(forType: .string) == nil, let image = NSImage(pasteboard: pb) else { return [] }
        return Attachment(image: image).map { [$0] } ?? []
    }
}
