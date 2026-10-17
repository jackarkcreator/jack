// A PDF annotation that draws an NSImage (the placed signature, a dropped image, ✔/✘).
// v3.0.2: the image draws through the PAGE (JackPage.draw), not PDFView's 1x annotation layer,
// which scaled it up and stair-stepped every edge at 200% — same fix as typed text and comment
// badges (JackFreeText.swift). v3.0.3: the selection outline is NOT drawn here any more —
// toggling it in PDFKit's cached layer never repainted on macOS 26, so it never showed. The
// document window draws it as a SelectionRing view over the page instead.
import PDFKit
import AppKit

final class ImageStampAnnotation: PDFAnnotation, PageDrawnAnnotation {
    let image: NSImage
    var outline = false   // selected (the ring is a view — see SelectionRing)
    /// Set while the user drags or slider-resizes the stamp: the layer copy follows live and
    /// the page skips it. Cleared at gesture end, which then forces a repaint.
    var liveDrag = false

    init(image: NSImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let layerCopy = page is JackPage && !liveDrag && !PageDrawScope.isActive
            && CGContextKind.isLayerBackingStore(context)
        if !layerCopy, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            PageDrawScope.noteDrawn(self)
            context.saveGState()
            context.interpolationQuality = .high
            context.draw(cg, in: bounds)
            context.restoreGState()
        }

    }

    var aspect: CGFloat {
        image.size.height <= 0 ? 1 : image.size.width / image.size.height
    }
}
