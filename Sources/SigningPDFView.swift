// PDFView subclass that lets the user click-and-drag a placed signature around the page.
import PDFKit
import AppKit

protocol StampSelectionDelegate: AnyObject {
    func didSelect(_ ann: ImageStampAnnotation?)
    func stampMoved(_ ann: ImageStampAnnotation, from oldBounds: CGRect)
    func redactionAdded(_ ann: RedactionAnnotation)
    func noteClicked(_ ann: PDFAnnotation)
}

final class SigningPDFView: PDFView {
    weak var stampDelegate: StampSelectionDelegate?
    var redactMode = false
    var annotateMenuItems: ((PDFPage?, CGPoint) -> [NSMenuItem])?

    // Right-click → annotate/comment directly from the context menu (page + point captured).
    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let page = page(for: viewPoint, nearest: true)
        let pagePoint = page.map { convert(viewPoint, to: $0) } ?? .zero
        guard let extra = annotateMenuItems?(page, pagePoint), !extra.isEmpty else { return base }
        let menu = base ?? NSMenu()
        if menu.items.isEmpty == false { menu.insertItem(.separator(), at: 0) }
        for item in extra.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }
    private var dragging: ImageStampAnnotation?
    private var dragPage: PDFPage?
    private var last: CGPoint = .zero
    private var dragStartBounds: CGRect = .zero
    // Redact rubber band: a plain view-space overlay (PDFView's page cache can't be trusted
    // to repaint annotation mutations live — see forceRefresh in DocumentWindowController).
    private var rubberBand: NSView?
    private var markOriginView: CGPoint = .zero
    private var markingPage: PDFPage?

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { super.mouseDown(with: event); return }
        let p = convert(viewPoint, to: page)
        if redactMode {
            markOriginView = viewPoint
            markingPage = page
            let band = NSView(frame: CGRect(origin: viewPoint, size: .zero))
            band.wantsLayer = true
            band.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
            band.layer?.borderColor = NSColor.systemRed.cgColor
            band.layer?.borderWidth = 1.5
            addSubview(band)
            rubberBand = band
            return
        }
        // Only the comment badge opens the note; the linked highlight stays plain text.
        if let note = page.annotations.last(where: {
            $0 is CommentBadgeAnnotation && $0.bounds.insetBy(dx: -4, dy: -4).contains(p)
        }) {
            stampDelegate?.noteClicked(note)
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
        if let band = rubberBand {
            let p = convert(event.locationInWindow, from: nil)
            band.frame = CGRect(x: min(markOriginView.x, p.x), y: min(markOriginView.y, p.y),
                                width: abs(p.x - markOriginView.x), height: abs(p.y - markOriginView.y))
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
        if let band = rubberBand {
            let viewRect = band.frame
            band.removeFromSuperview()
            rubberBand = nil
            defer { markingPage = nil }
            // Commit as one annotation with final bounds on the page where the drag started.
            if viewRect.width >= 4, viewRect.height >= 4, let page = markingPage {
                let a = convert(viewRect.origin, to: page)
                let b = convert(CGPoint(x: viewRect.maxX, y: viewRect.maxY), to: page)
                let pageRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                      width: abs(b.x - a.x), height: abs(b.y - a.y))
                guard pageRect.width >= 2, pageRect.height >= 2 else { return }
                let ann = RedactionAnnotation(bounds: pageRect)
                page.addAnnotation(ann)
                stampDelegate?.redactionAdded(ann)
            }
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
