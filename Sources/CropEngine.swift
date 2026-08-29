// Crop and region-snapshot, UI-free so the kill paths are testable headlessly.
//
// Two crops, labeled honestly in the UI:
// - STANDARD crop = CropBox change (what Adobe's Crop does). Reversible; the content outside
//   the crop is STILL IN THE FILE and recoverable — fine for layout, never for privacy.
// - PERMANENT crop = the page is re-rendered as pixels sized to the crop; content outside
//   verifiably ceases to exist (same rasterize discipline as RedactionEngine).
//
// Snapshot = Adobe's "Take a Snapshot": render a region at high resolution for the clipboard
// or a PNG on disk. Overlay marks (pending redactions/erases, comment badges) never appear
// in a snapshot; stamps and real annotations do.
import AppKit
import PDFKit

enum CropEngine {

    static let snapshotScale: CGFloat = 3.0   // 216 DPI — crisp for paste into docs/email

    /// A pixel-backed copy of `page` cropped to `rect` (page space). Text layer is destroyed
    /// by construction — that is the point of a permanent crop.
    static func permanentlyCropped(page: PDFPage, to rect: CGRect) -> PDFPage? {
        guard let img = render(page: page, region: rect, scale: RedactionEngine.rasterScale) else { return nil }
        var box = CGRect(origin: .zero, size: rect.size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
        ctx.beginPDFPage(info)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(img, in: box)
        ctx.restoreGState()
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    /// Region render for the snapshot tool.
    static func snapshotImage(page: PDFPage, region: CGRect) -> NSImage? {
        guard let cg = render(page: page, region: region, scale: snapshotScale) else { return nil }
        return NSImage(cgImage: cg, size: region.size)   // point size = region, backing = 3x
    }

    // MARK: - Internals

    /// Render `region` of the page into an RGB bitmap, overlay marks stripped, stamps burned.
    private static func render(page: PDFPage, region: CGRect, scale: CGFloat) -> CGImage? {
        let w = Int(region.width * scale), h = Int(region.height * scale)
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
        cg.translateBy(x: -region.origin.x, y: -region.origin.y)

        let overlays = page.annotations.filter {
            $0 is RedactionAnnotation || $0 is CommentBadgeAnnotation || $0.type == "Text"
        }
        let stamps = page.annotations.compactMap { $0 as? ImageStampAnnotation }
        (overlays + stamps).forEach { page.removeAnnotation($0) }
        page.draw(with: .mediaBox, to: cg)
        for s in stamps {
            if let img = s.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                cg.draw(img, in: s.bounds)
            }
            page.addAnnotation(s)
        }
        overlays.forEach { page.addAnnotation($0) }
        cg.restoreGState()
        return rep.cgImage
    }
}
