// PDFView subclass that lets the user click-and-drag a placed signature around the page.
import PDFKit
import AppKit

final class SigningPDFView: PDFView {
    weak var stampDelegate: SigningWindowController?
    private var dragging: ImageStampAnnotation?
    private var dragPage: PDFPage?
    private var last: CGPoint = .zero

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { super.mouseDown(with: event); return }
        let p = convert(viewPoint, to: page)
        if let ann = page.annotations.compactMap({ $0 as? ImageStampAnnotation }).last(where: { $0.bounds.contains(p) }) {
            dragging = ann; dragPage = page; last = p
            stampDelegate?.didSelect(ann)
        } else {
            // Don't deselect on a background click — keep the active signature selected.
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let ann = dragging, let page = dragPage else { super.mouseDragged(with: event); return }
        let p = convert(convert(event.locationInWindow, from: nil), to: page)
        var b = ann.bounds
        b.origin.x += p.x - last.x
        b.origin.y += p.y - last.y
        ann.bounds = b
        last = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragging != nil { dragging = nil; dragPage = nil } else { super.mouseUp(with: event) }
    }
}
