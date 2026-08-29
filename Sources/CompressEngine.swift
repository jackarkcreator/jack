// Compress PDF: scanned/image-only pages (no text layer) are re-rendered at 150 DPI JPEG;
// pages that carry text pass through as vectors, untouched. Honest compression — text never
// degrades, and the win comes from where the bloat actually lives (300+ DPI scans).
import AppKit
import PDFKit

enum CompressEngine {

    static let renderScale: CGFloat = 150.0 / 72.0
    static let jpegQuality: CGFloat = 0.7

    /// Returns (ok, compressedPageCount).
    static func compress(_ doc: PDFDocument, to url: URL) -> (Bool, Int) {
        guard let firstPage = doc.page(at: 0) else { return (false, 0) }
        var firstBox = firstPage.bounds(for: .mediaBox)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return (false, 0) }

        var compressed = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)

            let hasText = !((page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !hasText, let cg = rasterized(page: page) {
                compressed += 1
                ctx.saveGState()
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: box)
                ctx.restoreGState()
            } else {
                ctx.saveGState()
                page.draw(with: .mediaBox, to: ctx)
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return (true, compressed)
    }

    private static func rasterized(page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        // 150 DPI for normal pages, but never upscale a jumbo image-page (PDFPage(image:)
        // sizes the page in pixels-as-points) — cap the long edge at letter-at-150dpi.
        let maxLongEdge: CGFloat = 1650
        let scale = min(renderScale, maxLongEdge / max(box.width, box.height))
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = gctx.cgContext
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        cg.saveGState()
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: cg)
        cg.restoreGState()
        // JPEG round-trip so the embedded image (and the file) actually shrinks.
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]),
              let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
