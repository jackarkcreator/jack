// Measured geometry for Retype, so replacement text lands ON the old ink, not near it.
//
// PDFKit's FreeText annotation draws its text INSET from the annotation bounds (measured:
// ~3pt from the left, ~5.75pt from the top at 14pt — and it varies with the font), which is
// why naively placing bounds at the selection origin shifted the replacement right and down.
// Rather than hardcode today's values, calibrate per font by rendering a probe annotation
// offscreen and measuring where the ink actually starts. Cached; one small render per face.
import AppKit
import PDFKit

enum RetypeMetrics {

    private static var cache: [String: (left: CGFloat, top: CGFloat)] = [:]

    /// Where FreeText ink begins relative to the annotation's top-left, for this font.
    static func inkInset(for font: NSFont) -> (left: CGFloat, top: CGFloat) {
        let key = "\(font.fontName)@\(String(format: "%.1f", font.pointSize))"
        if let hit = cache[key] { return hit }

        var box = CGRect(x: 0, y: 0, width: 300, height: 120)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return (3, 6) }
        ctx.beginPDFPage(nil); ctx.setFillColor(.white); ctx.fill(box); ctx.endPDFPage(); ctx.closePDF()
        guard let doc = PDFDocument(data: data as Data), let page = doc.page(at: 0) else { return (3, 6) }

        let bounds = CGRect(x: 50, y: 40, width: 220, height: font.pointSize * 2 + 10)
        let probe = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        probe.contents = "Hx"                     // flat-topped, no overshoot
        probe.font = font
        probe.fontColor = .black
        probe.color = .clear
        let b = PDFBorder(); b.lineWidth = 0; probe.border = b
        page.addAnnotation(probe)

        let scale = 4
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300 * scale, pixelsHigh: 120 * scale,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return (3, 6) }
        let cg = g.cgContext
        cg.setFillColor(.white); cg.fill(CGRect(x: 0, y: 0, width: 300 * scale, height: 120 * scale))
        cg.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        page.draw(with: .mediaBox, to: cg)

        var minX = Int.max, minY = Int.max
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1 < 0.6 {
                minX = min(minX, x); minY = min(minY, y)
            }
        }
        guard minX != .max else { return (3, 6) }
        let result = (left: CGFloat(minX) / CGFloat(scale) - bounds.minX,
                      top: bounds.maxY - (120 - CGFloat(minY) / CGFloat(scale)))
        cache[key] = result
        return result
    }

    /// Page-space Y of the highest ink inside `rect` — the original text's true top edge, so
    /// the replacement can be placed on the SAME line rather than "somewhere in the rect".
    static func inkTop(of page: PDFPage, in rect: CGRect) -> CGFloat? {
        let scale = 4
        let w = Int(rect.width) * scale, h = Int(rect.height) * scale
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = g.cgContext
        cg.setFillColor(.white); cg.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        cg.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        cg.translateBy(x: -rect.minX, y: -rect.minY)
        page.draw(with: .mediaBox, to: cg)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1 < 0.7 {
                return rect.maxY - CGFloat(y) / CGFloat(scale)
            }
        }
        return nil
    }
}
