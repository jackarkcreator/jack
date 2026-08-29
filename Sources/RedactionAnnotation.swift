// A pending redaction mark: red-bordered dark overlay while marking. Rendered via PDFKit's
// native square-annotation appearance (custom draw overrides are not reliably honored for
// .square). On apply, RedactionEngine rasterizes the page and paints solid black in its place.
// Every flatten path MUST strip these before page.draw — baking one in as a gray box would be
// exactly the cosmetic redaction Jack exists to prevent.
import AppKit
import PDFKit

final class RedactionAnnotation: PDFAnnotation {
    init(bounds: CGRect) {
        super.init(bounds: bounds, forType: .square, withProperties: nil)
        color = .systemRed                                        // border
        interiorColor = NSColor.black.withAlphaComponent(0.55)    // fill
        let b = PDFBorder()
        b.lineWidth = 1.5
        border = b
        shouldDisplay = true
        shouldPrint = false
    }

    required init?(coder: NSCoder) { fatalError() }
}
