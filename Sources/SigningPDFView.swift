// PDFView subclass that lets the user click-and-drag a placed signature around the page.
import PDFKit
import AppKit

protocol StampSelectionDelegate: AnyObject {
    func didSelect(_ ann: ImageStampAnnotation?)
    func stampMoved(_ ann: ImageStampAnnotation, from oldBounds: CGRect)
    func redactionAdded(_ ann: RedactionAnnotation)
}

final class SigningPDFView: PDFView {
    weak var stampDelegate: StampSelectionDelegate?
    var redactMode = false
    private var dragging: ImageStampAnnotation?
    private var dragPage: PDFPage?
    private var last: CGPoint = .zero
    private var dragStartBounds: CGRect = .zero
    private var marking: RedactionAnnotation?
    private var markOrigin: CGPoint = .zero
    private var markingPage: PDFPage?

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { super.mouseDown(with: event); return }
        let p = convert(viewPoint, to: page)
        if redactMode {
            // Rubber-band a redaction mark.
            markOrigin = p
            let ann = RedactionAnnotation(bounds: CGRect(origin: p, size: .zero))
            page.addAnnotation(ann)
            marking = ann
            markingPage = page
            return
        }
        if let ann = page.annotations.compactMap({ $0 as? ImageStampAnnotation }).last(where: { $0.bounds.contains(p) }) {
            dragging = ann; dragPage = page; last = p
            dragStartBounds = ann.bounds
            stampDelegate?.didSelect(ann)
        } else {
            // Don't deselect on a background click — keep the active signature selected.
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let m = marking, let page = markingPage {
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            m.bounds = CGRect(x: min(markOrigin.x, p.x), y: min(markOrigin.y, p.y),
                              width: abs(p.x - markOrigin.x), height: abs(p.y - markOrigin.y))
            needsDisplay = true
            return
        }
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
        if let m = marking {
            if m.bounds.width < 4 || m.bounds.height < 4 {
                markingPage?.removeAnnotation(m)   // stray click, not a mark
            } else {
                stampDelegate?.redactionAdded(m)
            }
            marking = nil; markingPage = nil
            needsDisplay = true
            return
        }
        if let ann = dragging {
            if ann.bounds != dragStartBounds { stampDelegate?.stampMoved(ann, from: dragStartBounds) }
            dragging = nil; dragPage = nil
        } else {
            super.mouseUp(with: event)
        }
    }
}
