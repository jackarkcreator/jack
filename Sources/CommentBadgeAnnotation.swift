// The in-app comment marker: a small amber circle with a white speech-bubble glyph,
// vector-drawn (crisp at any zoom). Carries the note text in `contents`. Exported saves
// convert it to a standard PDF note annotation so other readers show their own icon.
import AppKit
import PDFKit

final class CommentBadgeAnnotation: PDFAnnotation {
    init(bounds: CGRect, text: String) {
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        contents = text
        shouldPrint = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(with box: PDFDisplayBox, in ctx: CGContext) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        ctx.saveGState()

        // Amber disc with a hairline white rim so it reads on any background.
        ctx.setFillColor(CGColor(red: 1.0, green: 0.72, blue: 0.05, alpha: 1))
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(max(0.75, r.width * 0.05))
        ctx.strokeEllipse(in: r)

        // White speech bubble: rounded rect + tail.
        let bw = r.width * 0.56, bh = r.height * 0.40
        let bx = r.midX - bw / 2
        let by = r.midY - bh / 2 + r.height * 0.08
        let corner = bh * 0.38
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: bx, y: by, width: bw, height: bh),
                           cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.fillPath()
        ctx.move(to: CGPoint(x: r.midX - bw * 0.18, y: by + 0.5))
        ctx.addLine(to: CGPoint(x: r.midX + bw * 0.10, y: by + 0.5))
        ctx.addLine(to: CGPoint(x: r.midX - bw * 0.08, y: by - bh * 0.42))
        ctx.closePath()
        ctx.fillPath()

        ctx.restoreGState()
    }
}
