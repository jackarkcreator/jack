// A PDF annotation that draws an NSImage (the placed signature).
import PDFKit
import AppKit

final class ImageStampAnnotation: PDFAnnotation {
    let image: NSImage
    var outline = false   // selection outline (on screen only; never flattened)

    init(image: NSImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(cg, in: bounds)
        context.restoreGState()

        if outline {
            context.saveGState()
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [6, 4])
            context.stroke(bounds.insetBy(dx: -3, dy: -3))
            context.restoreGState()
        }
    }

    var aspect: CGFloat {
        image.size.height <= 0 ? 1 : image.size.width / image.size.height
    }
}
