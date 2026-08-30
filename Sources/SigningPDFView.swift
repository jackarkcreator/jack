// PDFView subclass that lets the user click-and-drag a placed signature around the page.
import PDFKit
import AppKit

protocol StampSelectionDelegate: AnyObject {
    func didSelect(_ ann: ImageStampAnnotation?)
    func stampMoved(_ ann: ImageStampAnnotation, from oldBounds: CGRect)
    func noteClicked(_ ann: PDFAnnotation)
    func formFieldPlaced(kind: FormFieldKind, rect: CGRect, page: PDFPage)
    func formFieldEditRequested(name: String)
    func fieldResized(_ widget: PDFAnnotation, from oldBounds: CGRect)
    func dateFieldClicked(_ widget: PDFAnnotation, on page: PDFPage)
    // Form Kit (approved mock): build-mode selection + inline caption rename + delete,
    // fill-mode text/combo editors and toggle changes, live adornment tracking.
    func fieldSelected(name: String?, widget: PDFAnnotation?)
    func fieldBoundsChanging()
    func fieldDeleteRequested(name: String)
    func captionRenameRequested(_ label: PDFAnnotation, fieldName: String, on page: PDFPage)
    func fieldFillText(_ widget: PDFAnnotation, on page: PDFPage)
    func fieldFillCombo(_ widget: PDFAnnotation, on page: PDFPage)
    func fieldValueChanged()
    func fieldMoved(_ items: [(PDFAnnotation, CGRect)])
    func imageDropped(_ image: NSImage, at point: CGPoint, on page: PDFPage)
    // Typewriter: click empty page → place an editor; drag moves the text; double-click re-edits.
    func typewriterClicked(at point: CGPoint, on page: PDFPage)
    func freeTextMoved(_ ann: PDFAnnotation, from oldBounds: CGRect)
    func freeTextEditRequested(_ ann: PDFAnnotation)
    /// Instant erase/redact: the user lifted the mouse over `rect`; `band` is still covering
    /// it and should be dissolved (or removed) by the receiver once the paint is applied.
    func regionSwiped(_ rect: CGRect, on page: PDFPage, band: NSView, erase: Bool)
}

final class SigningPDFView: PDFView {
    weak var stampDelegate: StampSelectionDelegate?
    var redactMode = false
    // Typewriter: while on, a click on empty page area asks the delegate for a text editor.
    var typewriterMode = false
    // Form authoring: while on, widgets drag instead of accepting input; an armed kind
    // places a new field on click/drag (same rubber-band pattern as redact marks).
    var formAuthoringOn = false
    // Redact-mode bands commit as erase (whiteout) marks when this is set.
    var eraseStyle = false
    // One-shot region tool (snapshot/crop): armed from a menu, fires once, disarms itself.
    var regionAction: ((CGRect, PDFPage) -> Void)?
    var regionColor: NSColor = .systemTeal
    var armedFieldKind: FormFieldKind?
    private var resizingWidget: PDFAnnotation?
    private var resizeStart: CGRect = .zero
    /// Build-mode selection (the adornment view and ⌫ read this).
    private(set) var selectedField: (name: String, widget: PDFAnnotation)?

    func clearFieldSelection() {
        selectedField = nil
        stampDelegate?.fieldSelected(name: nil, widget: nil)
    }

    // Placeholders ("Type here") are armed ONLY while this view paints itself, so no
    // flatten, raster, OCR, or export path can ever bake them into a file.
    override func draw(_ dirtyRect: NSRect) {
        JackFormUI.placeholdersEnabled = true
        super.draw(dirtyRect)
        JackFormUI.placeholdersEnabled = false
    }

    override func keyDown(with event: NSEvent) {
        if formAuthoringOn, let sel = selectedField,
           event.charactersIgnoringModifiers == String(UnicodeScalar(NSDeleteCharacter)!) {
            stampDelegate?.fieldDeleteRequested(name: sel.name)
            return
        }
        super.keyDown(with: event)
    }
    var formFieldMenuItems: ((PDFAnnotation) -> [NSMenuItem])?
    var annotateMenuItems: ((PDFPage?, CGPoint) -> [NSMenuItem])?

    // Right-click → annotate/comment directly from the context menu (page + point captured).
    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let page = page(for: viewPoint, nearest: true)
        let pagePoint = page.map { convert(viewPoint, to: $0) } ?? .zero
        if formAuthoringOn, let page,
           let widget = page.annotations.last(where: { $0.type == "Widget" && $0.bounds.insetBy(dx: -4, dy: -4).contains(pagePoint) }),
           let items = formFieldMenuItems?(widget), !items.isEmpty {
            let menu = NSMenu()
            items.forEach { menu.addItem($0) }
            return menu
        }
        guard let extra = annotateMenuItems?(page, pagePoint), !extra.isEmpty else { return base }
        let menu = base ?? NSMenu()
        if menu.items.isEmpty == false { menu.insertItem(.separator(), at: 0) }
        for item in extra.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }
    private var dragging: ImageStampAnnotation?
    // Form drag: the whole field moves as a unit — widgets sharing the name + their labels.
    private var dragSet: [(PDFAnnotation, CGRect)] = []
    private var dragPrimary: PDFAnnotation?
    private var snapGuideV: NSView?
    private var snapGuideH: NSView?
    private var dragPage: PDFPage?
    private var dragStartMouse: CGPoint = .zero
    private var last: CGPoint = .zero
    private var dragStartBounds: CGRect = .zero
    // Typewriter text drag (FreeText is a plain PDFAnnotation, not our stamp subclass).
    private var draggingFree: PDFAnnotation?
    private var freeStartBounds: CGRect = .zero
    // Redact rubber band: a plain view-space overlay (PDFView's page cache can't be trusted
    // to repaint annotation mutations live — see forceRefresh in DocumentWindowController).
    private var rubberBand: NSView?
    private var markOriginView: CGPoint = .zero
    private var markingPage: PDFPage?
    private var bandFieldKind: FormFieldKind?   // set when the rubber band places a form field
    private var bandIsRegion = false            // set when the rubber band feeds regionAction

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { super.mouseDown(with: event); return }
        let p = convert(viewPoint, to: page)
        if regionAction != nil {
            bandIsRegion = true
            markOriginView = viewPoint
            markingPage = page
            let band = NSView(frame: CGRect(origin: viewPoint, size: .zero))
            band.wantsLayer = true
            band.layer?.backgroundColor = regionColor.withAlphaComponent(0.15).cgColor
            band.layer?.borderColor = regionColor.cgColor
            band.layer?.borderWidth = 1.5
            addSubview(band)
            rubberBand = band
            return
        }
        if formAuthoringOn {
            // Build mode, Keynote model (approved mock): click selects with handles, drag
            // moves the whole unit, the SE handle resizes, double-click the caption renames
            // in place, double-click a choice field opens its options.
            if let sel = selectedField, sel.widget.page === page,
               JackFormUI.seHandleHit(for: sel.widget.bounds).contains(p) {
                resizingWidget = sel.widget; resizeStart = sel.widget.bounds; dragPage = page
                return
            }
            let hit = page.annotations.last(where: { $0.type == "Widget" && $0.bounds.insetBy(dx: -2, dy: -2).contains(p) })
                ?? page.annotations.last(where: { FormFieldEngine.isLabel($0) && $0.bounds.contains(p) })
            if let hit {
                let fieldName: String?
                if hit.type == "Widget" {
                    fieldName = hit.fieldName
                } else if let nm = hit.userName {
                    let base = String(nm.dropFirst("jack-label:".count))
                    fieldName = base.components(separatedBy: ":opt:").first?
                        .components(separatedBy: ":kind:").first
                } else { fieldName = nil }
                guard let fieldName else { super.mouseDown(with: event); return }
                let set = page.annotations.filter {
                    ($0.type == "Widget" && $0.fieldName == fieldName) || FormFieldEngine.isLabel($0, for: fieldName)
                }
                let widget = set.first { $0.type == "Widget" } ?? hit
                if event.clickCount >= 2 {
                    if hit.type != "Widget", let nm = hit.userName, !nm.contains(":opt:") {
                        stampDelegate?.captionRenameRequested(hit, fieldName: fieldName, on: page)
                    } else {
                        stampDelegate?.formFieldEditRequested(name: fieldName)
                    }
                    return
                }
                selectedField = (fieldName, widget)
                stampDelegate?.fieldSelected(name: fieldName, widget: widget)
                dragSet = set.map { ($0, $0.bounds) }
                dragPrimary = widget
                dragPage = page; last = p; dragStartMouse = p
                dragStartBounds = widget.bounds
                return
            }
            clearFieldSelection()
            if let kind = armedFieldKind {
                bandFieldKind = kind
                markOriginView = viewPoint
                markingPage = page
                let band = NSView(frame: CGRect(origin: viewPoint, size: .zero))
                band.wantsLayer = true
                band.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.15).cgColor
                band.layer?.borderColor = NSColor.systemBlue.cgColor
                band.layer?.borderWidth = 1.5
                addSubview(band)
                rubberBand = band
                return
            }
            super.mouseDown(with: event)
            return
        }
        if redactMode {
            markOriginView = viewPoint
            markingPage = page
            let band = NSView(frame: CGRect(origin: viewPoint, size: .zero))
            band.wantsLayer = true
            if eraseStyle {
                band.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
                band.layer?.borderColor = NSColor.systemOrange.cgColor
            } else {
                band.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
                band.layer?.borderColor = NSColor.systemRed.cgColor
            }
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
        } else if let text = page.annotations.last(where: {
            $0.type == "FreeText" && $0.bounds.insetBy(dx: -3, dy: -3).contains(p)
        }) {
            // Typewriter text: double-click re-opens the editor, single click starts a drag.
            if event.clickCount >= 2 {
                stampDelegate?.freeTextEditRequested(text)
            } else {
                draggingFree = text; dragPage = page; last = p
                freeStartBounds = text.bounds
            }
        } else if let widget = page.annotations.last(where: {
            JackFormUI.isSupported($0) && $0.bounds.insetBy(dx: -2, dy: -2).contains(p)
        }), !redactMode {
            // Fill mode: fields are live (approved mock) — toggle, choose, type, pick a date.
            switch widget.widgetFieldType {
            case .button:
                if widget.widgetControlType == .radioButtonControl {
                    let group = page.annotations.filter { $0.type == "Widget" && $0.fieldName == widget.fieldName }
                    group.forEach { $0.buttonWidgetState = ($0 === widget) ? .onState : .offState }
                } else {
                    widget.buttonWidgetState = widget.buttonWidgetState == .onState ? .offState : .onState
                }
                stampDelegate?.fieldValueChanged()
            case .choice:
                stampDelegate?.fieldFillCombo(widget, on: page)
            default:
                if FormFieldEngine.isDateField(widget, on: page) {
                    stampDelegate?.dateFieldClicked(widget, on: page)
                } else {
                    stampDelegate?.fieldFillText(widget, on: page)
                }
            }
        } else if typewriterMode {
            stampDelegate?.typewriterClicked(at: p, on: page)
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
        if let w = resizingWidget, let page = dragPage {
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            let isButton = w.widgetControlType == .checkBoxControl || w.widgetControlType == .radioButtonControl
            var newW = max(16, p.x - resizeStart.minX)
            var newH = max(14, resizeStart.maxY - p.y)
            if isButton { let side = max(14, min(max(newW, newH), 40)); newW = side; newH = side }
            w.bounds = CGRect(x: resizeStart.minX, y: resizeStart.maxY - newH, width: newW, height: newH)
            needsDisplay = true
            stampDelegate?.fieldBoundsChanging()
            return
        }
        if !dragSet.isEmpty, let page = dragPage {
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            // Deltas from the DRAG START (never incremental — snapping would drift).
            var dx = p.x - dragStartMouse.x
            var dy = p.y - dragStartMouse.y
            // Smart snapping: the primary widget's edges pull toward other fields' edges.
            let proposed = dragStartBounds.offsetBy(dx: dx, dy: dy)
            let dragged = Set(dragSet.map { ObjectIdentifier($0.0) })
            let others = page.annotations.filter { $0.type == "Widget" && !dragged.contains(ObjectIdentifier($0)) }
            let tol: CGFloat = 6
            var snapX: CGFloat?
            var snapY: CGFloat?
            for o in others {
                for (mine, theirs) in [(proposed.minX, o.bounds.minX), (proposed.midX, o.bounds.midX)] {
                    if snapX == nil, abs(mine - theirs) < tol { dx += theirs - mine; snapX = theirs }
                }
                for (mine, theirs) in [(proposed.maxY, o.bounds.maxY), (proposed.minY, o.bounds.minY)] {
                    if snapY == nil, abs(mine - theirs) < tol { dy += theirs - mine; snapY = theirs }
                }
            }
            for (a, start) in dragSet { a.bounds = start.offsetBy(dx: dx, dy: dy) }
            updateSnapGuides(x: snapX, y: snapY, on: page)
            needsDisplay = true
            stampDelegate?.fieldBoundsChanging()
            return
        }
        if let free = draggingFree, let page = dragPage {
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            free.bounds = free.bounds.offsetBy(dx: p.x - last.x, dy: p.y - last.y)
            last = p
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
        if let band = rubberBand {
            let viewRect = band.frame
            // Instant erase/redact keep their band on screen: the controller applies the
            // paint and then dissolves the band over the result.
            if !redactMode { band.removeFromSuperview() }
            rubberBand = nil
            defer { markingPage = nil; bandFieldKind = nil; bandIsRegion = false }
            if bandIsRegion, let page = markingPage {
                let action = regionAction
                regionAction = nil                       // one-shot
                if viewRect.width >= 6, viewRect.height >= 6 {
                    let a = convert(viewRect.origin, to: page)
                    let b = convert(CGPoint(x: viewRect.maxX, y: viewRect.maxY), to: page)
                    let pageRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                          width: abs(b.x - a.x), height: abs(b.y - a.y))
                    if pageRect.width >= 4, pageRect.height >= 4 { action?(pageRect, page) }
                }
                return
            }
            // Form placement: a bare click (tiny rect) means "drop at default size" —
            // the controller normalizes. Anchor a click at the mouse-up point.
            if let kind = bandFieldKind, let page = markingPage {
                let upView = convert(event.locationInWindow, from: nil)
                let origin = viewRect.width >= 4 ? viewRect.origin : CGPoint(x: upView.x, y: upView.y)
                let a = convert(origin, to: page)
                let b = convert(CGPoint(x: origin.x + max(viewRect.width, 1), y: origin.y + max(viewRect.height, 1)), to: page)
                let pageRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                      width: abs(b.x - a.x), height: abs(b.y - a.y))
                stampDelegate?.formFieldPlaced(kind: kind, rect: pageRect, page: page)
                return
            }
            // ONE gesture for both: lift the mouse and it's applied (the controller verifies,
            // applies, and dissolves the band). Erase reads as blank paper; redact lands the
            // black bar the moment you let go — Keno's call, 2026-08-30.
            if let page = markingPage {
                if viewRect.width >= 4, viewRect.height >= 4 {
                    let a = convert(viewRect.origin, to: page)
                    let b = convert(CGPoint(x: viewRect.maxX, y: viewRect.maxY), to: page)
                    let pageRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                          width: abs(b.x - a.x), height: abs(b.y - a.y))
                    stampDelegate?.regionSwiped(pageRect, on: page, band: band, erase: eraseStyle)
                } else {
                    band.removeFromSuperview()
                }
            } else {
                band.removeFromSuperview()
            }
            return
        }
        if let w = resizingWidget {
            if w.bounds != resizeStart { stampDelegate?.fieldResized(w, from: resizeStart) }
            resizingWidget = nil; dragPage = nil
            return
        }
        if !dragSet.isEmpty {
            clearSnapGuides()
            let moved = dragSet.filter { $0.0.bounds != $0.1 }
            if !moved.isEmpty { stampDelegate?.fieldMoved(moved) }
            dragSet = []; dragPrimary = nil; dragPage = nil
            return
        }
        if let ann = dragging {
            if ann.bounds != dragStartBounds { stampDelegate?.stampMoved(ann, from: dragStartBounds) }
            dragging = nil; dragPage = nil
        } else if let free = draggingFree {
            if free.bounds != freeStartBounds { stampDelegate?.freeTextMoved(free, from: freeStartBounds) }
            draggingFree = nil; dragPage = nil
        } else {
            super.mouseUp(with: event)
        }
    }

    // MARK: Snap guides — plain view-space overlays (zero PDFKit, per the render law)

    private func updateSnapGuides(x: CGFloat?, y: CGFloat?, on page: PDFPage) {
        func line(_ frame: CGRect, _ existing: inout NSView?) {
            let v = existing ?? {
                let v = NSView()
                v.wantsLayer = true
                v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
                addSubview(v)
                existing = v
                return v
            }()
            v.frame = frame
        }
        if let x {
            let vp = convert(CGPoint(x: x, y: 0), from: page)
            line(CGRect(x: vp.x - 0.5, y: 0, width: 1, height: bounds.height), &snapGuideV)
        } else { snapGuideV?.removeFromSuperview(); snapGuideV = nil }
        if let y {
            let vp = convert(CGPoint(x: 0, y: y), from: page)
            line(CGRect(x: 0, y: vp.y - 0.5, width: bounds.width, height: 1), &snapGuideH)
        } else { snapGuideH?.removeFromSuperview(); snapGuideH = nil }
    }

    private func clearSnapGuides() {
        snapGuideV?.removeFromSuperview(); snapGuideV = nil
        snapGuideH?.removeFromSuperview(); snapGuideH = nil
    }

    // MARK: Image drop — drag a logo (or any image file) straight onto the page

    private static let imageDropTypes: [NSPasteboard.PasteboardType] = [.fileURL, .tiff, .png]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(Self.imageDropTypes)
    }

    private func droppedImage(from pb: NSPasteboard) -> NSImage? {
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL],
           let url = urls.first, let img = NSImage(contentsOf: url) {
            return img
        }
        if let img = NSImage(pasteboard: pb), img.size.width > 0 { return img }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedImage(from: sender.draggingPasteboard) != nil ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedImage(from: sender.draggingPasteboard) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let img = droppedImage(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        let viewPoint = convert(sender.draggingLocation, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return false }
        stampDelegate?.imageDropped(img, at: convert(viewPoint, to: page), on: page)
        return true
    }
}
