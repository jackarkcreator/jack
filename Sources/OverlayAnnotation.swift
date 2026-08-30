// Live watermark + Bates numbering.
//
// Both were file-spawning tools: pick options, choose a filename, get a copy. Now they are
// objects on the open document — visible immediately, undoable, removable — and they burn into
// the page only when the user saves.
//
// They burn as REAL VECTOR CONTENT, not as a raster overlay, which is why these are custom
// annotations that draw themselves rather than ImageStampAnnotations carrying a picture:
//   - a Bates number is a legal production artifact and MUST stay extractable and searchable
//     in the saved file (an image of a number is worthless in discovery);
//   - a watermark stays crisp at any zoom and keeps real alpha over the page beneath it.
// The same `drawInto` is used for the on-screen appearance and for the flatten at save, so what
// you see is what gets written — there is no second drawing path to drift out of sync.
//
// 🧨 Custom PDFAnnotation subclasses do NOT render through `page.draw`. Every path that
// flattens or rasterizes a page (JackDocument.flattenedCopy, RedactionEngine, CropEngine) must
// call drawInto explicitly, exactly as it already does for ImageStampAnnotation — otherwise the
// mark silently disappears from that output.
import AppKit
import PDFKit

/// A mark that lives on the page and is burned into it at save time.
class OverlayAnnotation: PDFAnnotation {

    /// Draw into a context already in PAGE coordinate space. Used for both screen and flatten.
    func drawInto(_ ctx: CGContext, pageBox: CGRect) {}

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        drawInto(context, pageBox: page?.bounds(for: .mediaBox) ?? bounds)
    }
}

/// Diagonal watermark across a page ("CONFIDENTIAL", "DRAFT", a client name…).
final class WatermarkAnnotation: OverlayAnnotation {
    let text: String
    let opacity: CGFloat

    init(text: String, opacity: CGFloat, pageBox: CGRect) {
        self.text = text
        self.opacity = opacity
        super.init(bounds: pageBox, forType: .stamp, withProperties: nil)
        shouldPrint = true
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func drawInto(_ ctx: CGContext, pageBox box: CGRect) {
        let base: CGFloat = 60
        let attrs: (CGFloat) -> NSAttributedString = { size in
            NSAttributedString(string: self.text, attributes: [
                .font: NSFont.boldSystemFont(ofSize: size),
                .foregroundColor: NSColor.black.withAlphaComponent(self.opacity)
            ])
        }
        var line = CTLineCreateWithAttributedString(attrs(base))
        var w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard w > 0 else { return }
        // Size to ~70% of the page diagonal, then centre and rotate along it.
        let size = base * (hypot(box.width, box.height) * 0.7) / w
        line = CTLineCreateWithAttributedString(attrs(size))
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

/// Sequential page numbering for legal production. The NUMBER is derived from the page's
/// current index every time it is drawn, so reordering, deleting or merging pages renumbers
/// the whole document with no bookkeeping — and no stale numbers can ever be saved.
final class BatesAnnotation: OverlayAnnotation {
    let prefix: String
    let start: Int
    let digits: Int
    let corner: StampEngine.Corner
    let fontSize: CGFloat

    init(prefix: String, start: Int, digits: Int, corner: StampEngine.Corner,
         fontSize: CGFloat = 10, pageBox: CGRect) {
        self.prefix = prefix
        self.start = start
        self.digits = digits
        self.corner = corner
        self.fontSize = fontSize
        super.init(bounds: pageBox, forType: .stamp, withProperties: nil)
        shouldPrint = true
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Label for a given zero-based page index.
    func label(forPageIndex i: Int) -> String {
        prefix + String(format: "%0\(max(1, digits))d", start + i)
    }

    /// Current index of the page this annotation sits on, or 0 if it is not attached yet.
    private var pageIndex: Int {
        guard let p = page, let doc = p.document else { return 0 }
        let i = doc.index(for: p)
        return i == NSNotFound ? 0 : i
    }

    override func drawInto(_ ctx: CGContext, pageBox box: CGRect) {
        draw(label: label(forPageIndex: pageIndex), into: ctx, pageBox: box)
    }

    /// Flatten paths know the page index directly and must not depend on annotation attachment.
    func drawInto(_ ctx: CGContext, pageBox box: CGRect, pageIndex i: Int) {
        draw(label: label(forPageIndex: i), into: ctx, pageBox: box)
    }

    private func draw(label: String, into ctx: CGContext, pageBox box: CGRect) {
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

extension PDFPage {
    var overlayAnnotations: [OverlayAnnotation] { annotations.compactMap { $0 as? OverlayAnnotation } }
}
