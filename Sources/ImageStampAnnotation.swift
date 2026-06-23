// A PDF annotation that draws an NSImage (the placed signature).
import PDFKit
import AppKit

final class ImageStampAnnotation: PDFAnnotation {
    let image: NSImage

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
    }

    var aspect: CGFloat {
        image.size.height <= 0 ? 1 : image.size.width / image.size.height
    }
}
