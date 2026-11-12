// The Drop Shelf — a target that exists only while you drag (approved mock 2026-08-30).
//
// Pick up files anywhere in macOS and a small frosted Jack panel slides into the
// bottom-right corner, its label already reading the drag and stating exactly what a
// drop will do. Release anywhere else and it vanishes. Zero standing chrome.
//
// Mechanism (no special permissions): the system DRAG pasteboard's changeCount ticks
// when a drag starts — a 5Hz watcher classifies the payload and shows the shelf only
// for drags Jack can serve (or honestly refuse). Dismissal keys off the physical mouse
// buttons releasing (NSEvent.pressedMouseButtons), which also covers Esc-cancelled
// drags that never emit a mouse-up.
import AppKit
import UniformTypeIdentifiers

final class DropShelf {
    static let prefKey = "jack.shelfEnabled"
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: prefKey) == nil
            ? true : UserDefaults.standard.bool(forKey: prefKey)
    }

    private let onDrop: ([URL]) -> Void
    private let onConvert: ([URL]) -> Void
    private var zones: [ShelfZoneView] = []
    private var heading: NSTextField?
    private var panelSplit: Bool?
    private var panel: NSPanel?
    private var timer: Timer?
    private var lastChange = NSPasteboard(name: .drag).changeCount
    private var pendingShow: DispatchWorkItem?

    /// `onDrop` routes a drop the classic way; `onConvert` gets the PDFs dropped on Convert to Word (3.5 C1).
    init(onDrop: @escaping ([URL]) -> Void, onConvert: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
        self.onConvert = onConvert
        // 5Hz pasteboard watch is effectively free; it also polices dismissal.
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let pb = NSPasteboard(name: .drag)
        if pb.changeCount != lastChange {
            lastChange = pb.changeCount
            jackdrag("shelf change: enabled=\(Self.enabled) buttons=\(NSEvent.pressedMouseButtons) fileURL=\(pb.availableType(from: [.fileURL]) != nil) types=\(pb.types?.map { $0.rawValue } ?? [])")
            // 🧨 READING a live drag's pasteboard can disturb the drag session itself —
            // Jack's own page drags (Organize, sidebar) were springing back once the
            // watcher glanced at them. availableType is a declared-types peek that
            // resolves nothing: drags carrying no files are never touched at all.
            guard Self.enabled, NSEvent.pressedMouseButtons != 0,
                  pb.availableType(from: [.fileURL]) != nil else { return }
            // 🧨 Real Finder drags declare ONLY public.file-url + com.apple.finder.node —
            // no content UTIs — so classification MUST read the URLs (proven by tick
            // probe, 2026-08-30). Reading the drag pasteboard is safe; the organizer
            // spring-back was the gap-indicator exception, never this read. The guard
            // above keeps Jack's own internal page drags untouched.
            let urls = (pb.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            jackdrag("shelf tick: \(urls.count) urls")
            if let content = Self.classify(urls) {
                jackdrag("shelf classify -> \(content.action)")
                // Appear ~0.25s into the drag — ephemeral drags never see it (mock timing).
                pendingShow?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    if NSEvent.pressedMouseButtons != 0 { self?.show(content) }
                }
                pendingShow = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
        }
        // Mouse released anywhere (including Esc-cancelled drags): the show is over.
        // (Only while shown: hiding an already-hidden panel 5x a second forever was log spam.)
        if panel?.isVisible == true, NSEvent.pressedMouseButtons == 0 { hide() }
    }

    // MARK: What a drop will do — the label is the contract (mock variants, 1:1)

    /// One half of a split shelf (3.5 C1): where you let go is the answer.
    struct Zone { let action: String; let detail: String; let glyph: CardGlyph.Kind; let toWord: Bool }
    struct Content {
        let action: String
        let detail: String
        var split: (left: Zone, right: Zone)? = nil
        var heading = ""
    }


    static func classify(_ urls: [URL]) -> Content? {
        guard !urls.isEmpty else { return nil }
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        if let folder = folders.first {
            return Content(action: "Batch process this folder",
                           detail: folder.lastPathComponent + " · OCR · Bates · watermark · compress")
        }
        let photos = urls.filter(isImageURL)
        let pdfs = urls.filter(isPDFURL)
        let docs = urls.filter(ConvertEngine.isConvertible)
        let refused = urls.filter(ConvertEngine.isRefused)
        if !refused.isEmpty, photos.isEmpty, pdfs.isEmpty, docs.isEmpty {
            return Content(action: "Can\u{2019}t convert spreadsheets",
                           detail: "They keep their layout best exported from the app that made them")
        }
        if !docs.isEmpty, photos.isEmpty, pdfs.isEmpty {
            return docs.count == 1
                ? Content(action: "Convert to PDF", detail: docs[0].lastPathComponent + " · saved beside it")
                : Content(action: "Convert \(docs.count) documents to PDF", detail: "each saved beside its original")
        }
        if pdfs.count == 1, photos.isEmpty, docs.isEmpty {
            return Content(action: "Open in Jack", detail: pdfs[0].lastPathComponent,
                           split: (Zone(action: "Open in Jack", detail: "read \u{00B7} mark up \u{00B7} sign", glyph: .open, toWord: false),
                                   Zone(action: "Convert to Word", detail: ".docx saved beside it", glyph: .word, toWord: true)),
                           heading: pdfs[0].lastPathComponent)
        }
        if pdfs.count > 1, photos.isEmpty, docs.isEmpty {
            return Content(action: "Organize \(pdfs.count) items into one PDF", detail: "\(pdfs.count) PDFs, in order",
                           split: (Zone(action: "Organize into one PDF", detail: "in order", glyph: .organize, toWord: false),
                                   Zone(action: "Convert each to Word", detail: "\(pdfs.count) .docx files, beside each", glyph: .word, toWord: true)),
                           heading: "\(pdfs.count) PDFs")
        }
        if !photos.isEmpty, pdfs.isEmpty, docs.isEmpty {
            return photos.count == 1
                ? Content(action: "Turn 1 photo into a PDF", detail: "Saved to Desktop · opens in Jack")
                : Content(action: "Combine \(photos.count) photos into one PDF",
                          detail: "Saved to Desktop · opens in Jack")
        }
        if !pdfs.isEmpty || !photos.isEmpty {
            let n = pdfs.count + photos.count
            var parts: [String] = []
            if !pdfs.isEmpty { parts.append("\(pdfs.count) PDF\(pdfs.count == 1 ? "" : "s")") }
            if !photos.isEmpty { parts.append("\(photos.count) photo\(photos.count == 1 ? "" : "s")") }
            return Content(action: "Organize \(n) items into one PDF", detail: parts.joined(separator: " + ") + ", in order")
        }
        if !docs.isEmpty {
            return Content(action: "Convert \(docs.count) documents to PDF", detail: "each saved beside its original")
        }
        return nil
    }

    // MARK: Show / hide

    private func show(_ content: Content) {
        let split = content.split != nil
        if panel == nil || panelSplit != split { panel?.orderOut(nil); buildPanel(split: split) }
        guard let panel else { return }
        if let sp = content.split, zones.count == 2 {
            for (z, spec) in zip(zones, [sp.left, sp.right]) {
                z.actLabel.stringValue = spec.action
                z.detLabel.stringValue = spec.detail
                z.glyphKind = spec.glyph
                z.toWord = spec.toWord
            }
            heading?.stringValue = content.heading
        } else if let zone = zones.first {
            zone.actLabel.stringValue = content.action
            zone.detLabel.stringValue = content.detail
        }
        // Corner of whichever screen holds the cursor (mock: bottom-right, 22pt in).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 22, y: vf.minY + 22))
        if !panel.isVisible {
            panel.orderFrontRegardless()
            // Slide in from the right with a light overshoot (mock's 0.3s spring).
            let slide = CASpringAnimation(keyPath: "transform.translation.x")
            slide.fromValue = 60
            slide.toValue = 0
            slide.damping = 14
            slide.stiffness = 260
            slide.mass = 1
            slide.duration = slide.settlingDuration
            panel.contentView?.layer?.add(slide, forKey: "slidein")
        }
    }

    /// Self-test only: show the shelf for these files without a drag and hand back its view.
    func showcase(_ urls: [URL]) -> NSView? {
        guard let c = Self.classify(urls) else { return nil }
        show(c)
        return panel?.contentView
    }

    func hide() {
        pendingShow?.cancel()
        panel?.orderOut(nil)
        zones.forEach { $0.setHot(false) }
    }

    // MARK: The panel — 1:1 with the approved mock

    private func buildPanel(split: Bool) {
        let width: CGFloat = split ? 352 : 248
        let height: CGFloat = split ? 214 : 168
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .aqua)   // the mock's light frost, everywhere
        let frost = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        frost.material = .popover
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.wantsLayer = true
        frost.layer?.cornerRadius = 16
        frost.layer?.masksToBounds = true
        frost.layer?.borderWidth = 0.5
        frost.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        var made: [ShelfZoneView] = []
        let frames: [NSRect] = split
            ? [NSRect(x: 16, y: 30, width: (width - 44) / 2, height: 128),
               NSRect(x: 16 + (width - 44) / 2 + 12, y: 30, width: (width - 44) / 2, height: 128)]
            : [NSRect(x: 16, y: 30, width: width - 32, height: height - 46)]
        for f in frames {
            let z = ShelfZoneView(frame: f)
            z.onDrop = { [weak self, weak z] urls in
                self?.hide()
                if z?.toWord == true { self?.onConvert(urls.filter(isPDFURL)) } else { self?.onDrop(urls) }
            }
            frost.addSubview(z)
            made.append(z)
        }
        heading = nil
        if split {
            let h = NSTextField(labelWithString: "")
            h.font = .systemFont(ofSize: 11.5)
            h.textColor = NSColor(calibratedRed: 0.357, green: 0.373, blue: 0.404, alpha: 1)
            h.alignment = .center
            h.lineBreakMode = .byTruncatingMiddle
            h.frame = NSRect(x: 16, y: height - 14 - 15, width: width - 32, height: 15)
            frost.addSubview(h)
            heading = h
        }
        let esc = NSTextField(labelWithString: "release anywhere else to dismiss")
        esc.font = .systemFont(ofSize: 10)
        esc.textColor = NSColor(calibratedRed: 0.435, green: 0.439, blue: 0.463, alpha: 1)
        esc.alignment = .center
        esc.frame = NSRect(x: 0, y: 9, width: width, height: 13)
        frost.addSubview(esc)
        p.contentView = frost
        panel = p
        zones = made
        panelSplit = split
    }
}

/// The dashed drop zone: accent dashed border at rest, solid + tinted while a drag hovers,
/// teal-gradient glyph (up-arrow into a tray), action + detail labels — the mock, in AppKit.
final class ShelfZoneView: NSView {
    var onDrop: (([URL]) -> Void)?
    /// Split shelf: this zone converts to Word instead of opening/organizing.
    var toWord = false
    var glyphKind: CardGlyph.Kind = .open { didSet { glyph.kind = glyphKind; glyph.needsDisplay = true } }
    private let glyph = CardGlyph(kind: .open)
    let actLabel = NSTextField(labelWithString: "")
    let detLabel = NSTextField(labelWithString: "")
    private let border = CAShapeLayer()
    private let fill = CALayer()
    private(set) var isHot = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])

        fill.frame = bounds
        fill.cornerRadius = 11
        fill.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(fill)

        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 11, cornerHeight: 11, transform: nil)
        border.fillColor = NSColor.clear.cgColor
        border.strokeColor = NSColor(calibratedRed: 0.055, green: 0.522, blue: 0.467, alpha: 0.75).cgColor
        border.lineWidth = 2
        border.lineDashPattern = [6, 5]
        layer?.addSublayer(border)

        glyph.frame = NSRect(x: bounds.midX - 17, y: bounds.height - 16 - 34, width: 34, height: 34)
        addSubview(glyph)

        actLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        actLabel.textColor = NSColor(calibratedRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
        actLabel.alignment = .center
        actLabel.lineBreakMode = .byWordWrapping
        actLabel.maximumNumberOfLines = 2
        actLabel.frame = NSRect(x: 8, y: bounds.height - 58 - 36, width: bounds.width - 16, height: 36)
        addSubview(actLabel)

        detLabel.font = .systemFont(ofSize: 11)
        detLabel.textColor = NSColor(calibratedRed: 0.431, green: 0.431, blue: 0.451, alpha: 1)
        detLabel.alignment = .center
        detLabel.lineBreakMode = .byTruncatingMiddle
        detLabel.frame = NSRect(x: 6, y: 10, width: bounds.width - 12, height: 15)
        addSubview(detLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setHot(_ hot: Bool) {
        isHot = hot
        border.lineDashPattern = hot ? nil : [6, 5]
        fill.backgroundColor = hot
            ? NSColor(calibratedRed: 0.055, green: 0.522, blue: 0.467, alpha: 0.10).cgColor
            : NSColor.clear.cgColor
    }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        setHot(true)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { setHot(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHot(false)
        let u = urls(sender)
        guard !u.isEmpty else { return false }
        onDrop?(u)
        return true
    }
}
