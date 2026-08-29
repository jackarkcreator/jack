// Bates numbering + watermark: write a stamped copy of the document. Stamps are drawn as
// REAL text into the page content (extractable, printable) — not annotations.
import AppKit
import PDFKit

enum StampEngine {

    enum Corner: Int { case bottomRight = 0, bottomLeft, topRight, topLeft }

    /// Bates: "<prefix><zero-padded number>" per page, incrementing. Returns success.
    static func bates(_ doc: PDFDocument, to url: URL, prefix: String, start: Int,
                      digits: Int, corner: Corner, fontSize: CGFloat = 10) -> Bool {
        stamp(doc, to: url) { ctx, box, pageIndex in
            let label = prefix + String(format: "%0\(max(1, digits))d", start + pageIndex)
            let attr = NSAttributedString(string: label, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.black
            ])
            let line = CTLineCreateWithAttributedString(attr)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let m: CGFloat = 18   // margin
            let pos: CGPoint
            switch corner {
            case .bottomRight: pos = CGPoint(x: box.maxX - m - w, y: box.minY + m)
            case .bottomLeft:  pos = CGPoint(x: box.minX + m, y: box.minY + m)
            case .topRight:    pos = CGPoint(x: box.maxX - m - w, y: box.maxY - m - fontSize)
            case .topLeft:     pos = CGPoint(x: box.minX + m, y: box.maxY - m - fontSize)
            }
            ctx.textMatrix = .identity
            ctx.textPosition = pos
            CTLineDraw(line, ctx)
        }
    }

    /// Diagonal watermark across every page ("CONFIDENTIAL", "DRAFT", a client name…).
    static func watermark(_ doc: PDFDocument, to url: URL, text: String,
                          opacity: CGFloat = 0.15) -> Bool {
        stamp(doc, to: url) { ctx, box, _ in
            let base: CGFloat = 60
            let font = NSFont.boldSystemFont(ofSize: base)
            let attr = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor.black.withAlphaComponent(opacity)
            ])
            var line = CTLineCreateWithAttributedString(attr)
            var w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            guard w > 0 else { return }
            // Size to ~70% of the diagonal.
            let diagonal = hypot(box.width, box.height)
            let size = base * (diagonal * 0.7) / w
            line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.boldSystemFont(ofSize: size),
                .foregroundColor: NSColor.black.withAlphaComponent(opacity)
            ]))
            w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.saveGState()
            ctx.translateBy(x: box.midX, y: box.midY)
            ctx.rotate(by: atan2(box.height, box.width))
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: -w / 2, y: 0)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    // Shared: copy every page, then let `draw` add the stamp on top.
    private static func stamp(_ doc: PDFDocument, to url: URL,
                              draw: (CGContext, CGRect, Int) -> Void) -> Bool {
        guard let firstPage = doc.page(at: 0) else { return false }
        var firstBox = firstPage.bounds(for: .mediaBox)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return false }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.saveGState()
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
            draw(ctx, box, i)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return true
    }
}
