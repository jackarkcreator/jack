// A pending redaction mark: red-bordered dark overlay while marking. Destroyed (not drawn)
// on apply — RedactionEngine rasterizes the page and paints solid black in its place.
import AppKit
import PDFKit

final class RedactionAnnotation: PDFAnnotation {
    init(bounds: CGRect) {
        super.init(bounds: bounds, forType: .square, withProperties: nil)
        shouldDisplay = true
        shouldPrint = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        context.fill(bounds)
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(1.5)
        context.stroke(bounds.insetBy(dx: 0.75, dy: 0.75))
        context.restoreGState()
    }
}
