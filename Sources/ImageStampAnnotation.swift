// A PDF annotation that draws an NSImage (the placed signature, a dropped image, ✔/✘).
// v3.0.2: the image draws through the PAGE (JackPage.draw), not PDFView's 1x annotation layer,
// which scaled it up and stair-stepped every edge at 200% — same fix as typed text and comment
// badges (JackFreeText.swift). The selection outline stays in the layer: it is screen-only
// chrome, so it never reaches a page draw (thumbnails, flattens, rasters).
import PDFKit
import AppKit

final class ImageStampAnnotation: PDFAnnotation, PageDrawnAnnotation {
    let image: NSImage
    var outline = false   // selection outline (on screen only; never flattened)
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

        if outline, !PageDrawScope.isActive {
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
