// The menu bar popover: Jack's compact launcher — a 2×3 action grid and settings.
// v3 (ratified mock): app header, a real drop zone, tinted tiles, switches (no ★ checkbox).
import AppKit

/// One launcher action: a tinted icon square + label on a quiet rounded tile.
final class LauncherTile: NSButton {
    private var hovering = false
    private let label: String
    private let symbolImage: NSImage?

    init(symbol: String, label: String, target: AnyObject?, action: Selector?) {
        self.label = label
        self.symbolImage = Chrome.symbol([symbol], label, .init(pointSize: 15, weight: .medium))
        super.init(frame: .zero)
        title = label
        isBordered = false
        setButtonType(.momentaryChange)
        self.target = target
        self.action = action
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            Chrome.panelTile.setFill()
            tile.fill()
            if isHighlighted { Chrome.pressFill.setFill(); tile.fill() }
            else if hovering { Chrome.hoverFill.setFill(); tile.fill() }
            Chrome.groupStroke.setStroke(); tile.lineWidth = 0.5; tile.stroke()
            let sq = NSRect(x: 12, y: (bounds.height - 30) / 2, width: 30, height: 30)
            Chrome.tintSoft.setFill()
            NSBezierPath(roundedRect: sq, xRadius: 9, yRadius: 9).fill()
            if let img = symbolImage {
                let s = img.size
                tinted(img, Chrome.tint).draw(in: NSRect(x: sq.midX - s.width / 2, y: sq.midY - s.height / 2,
                                                         width: s.width, height: s.height))
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                                                        .foregroundColor: NSColor.labelColor]
            let ts = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: NSPoint(x: sq.maxX + 10, y: (bounds.height - ts.height) / 2), withAttributes: attrs)
        }
    }
}

/// The popover's root: the ENTIRE surface accepts file drops (the header promises
/// "drop anywhere" — as of v2.9.5 it's true). While a drag hovers, a big accent drop
/// state takes over so the action is unmistakable.
final class DropSurfaceView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onDragState: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    /// 3.1: a solid panel, not see-through glass (tiles washed out over white pages).
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { Chrome.panelFill.setFill(); bounds.fill() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { isPDFURL($0) || isImageURL($0) || ConvertEngine.isConvertible($0)
                || ConvertEngine.isRefused($0)
                || ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        onDragState?(true)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragState?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onDragState?(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragState?(false)
        let u = urls(sender)
        guard !u.isEmpty else { return false }
        onDrop?(u)
        return true
    }
}

final class HomePopoverViewController: NSViewController {
    var onNew: (() -> Void)?
    var onOpen: (() -> Void)?
    var onPhotos: (() -> Void)?
    var onSign: (() -> Void)?
    var onOrganize: (() -> Void)?
    var onBatch: (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?
    var onMakeDefault: (() -> Void)?
    var onQuit: (() -> Void)?
    var onUpdate: (() -> Void)?
    var onToggleLogin: ((Bool) -> Void)?
    var onToggleShelf: ((Bool) -> Void)?
    var loginEnabled = false { didSet { loginCheck?.state = loginEnabled ? .on : .off } }
    var shelfEnabled = true { didSet { shelfCheck?.state = shelfEnabled ? .on : .off } }
    private var shelfCheck: NSSwitch?
    var defaultEnabled = false {
        didSet {
            defaultCheck?.state = defaultEnabled ? .on : .off
        }
    }
    private var defaultCheck: NSSwitch?
    private var loginCheck: NSSwitch?

    /// The launcher's header glyph: a Jack-teal squircle with a page.
    static func appGlyph() -> NSImage {
        NSImage(size: NSSize(width: 28, height: 28), flipped: false) { r in
            let g = NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.72, blue: 0.65, alpha: 1),
                               ending: NSColor(srgbRed: 0.055, green: 0.43, blue: 0.43, alpha: 1))
            g?.draw(in: NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7), angle: -70)
            if let doc = Chrome.symbol(["doc.text"], "Jack", .init(pointSize: 14, weight: .semibold)) {
                let s = doc.size
                tinted(doc, .white).draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
    private let updateButton = NSButton(title: "Update", target: nil, action: nil)
    private var updateURL: URL?

    func showUpdate(version: String, url: URL) {
        updateURL = url
        updateButton.title = "Update to \(version)"
        updateButton.isHidden = false
    }

    private static let width: CGFloat = 312
    private static let height: CGFloat = 388

    private let dropOverlay = NSVisualEffectView()

    override func loadView() {
        let v = DropSurfaceView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        v.onDrop = { [weak self] urls in self?.onFilesDropped?(urls) }
        v.onDragState = { [weak self] active in self?.dropOverlay.isHidden = !active }

        // Header: app glyph + name + the promise.
        let glyph = NSImageView(frame: NSRect(x: 16, y: Self.height - 44, width: 28, height: 28))
        glyph.wantsLayer = true
        glyph.layer?.cornerRadius = 7
        glyph.layer?.masksToBounds = true
        glyph.image = Self.appGlyph()
        v.addSubview(glyph)
        let name = NSTextField(labelWithString: "Jack")
        name.font = Chrome.titleFont
        name.frame = NSRect(x: 54, y: Self.height - 30, width: 200, height: 17)
        v.addSubview(name)
        let promise = NSTextField(labelWithString: "Everything stays on this Mac")
        promise.font = Chrome.metaFont
        promise.textColor = .tertiaryLabelColor
        promise.frame = NSRect(x: 54, y: Self.height - 45, width: 220, height: 14)
        v.addSubview(promise)

        // 3.1: no drop box — the Drop Shelf catches drags, and dropping on the menu-bar icon
        // (or anywhere on this panel) still works; it just isn't advertised with a box.
        // 2×3 grid — same six actions as always.
        let cards: [(String, String, Selector)] = [
            ("doc.badge.plus", "New PDF", #selector(newPDF)),
            ("folder", "Open", #selector(openPDF)),
            ("photo.on.rectangle", "Combine", #selector(photos)),
            ("signature", "Sign", #selector(sign)),
            ("doc.on.doc", "Organize", #selector(organize)),
            ("checklist", "Batch", #selector(batch))
        ]
        let cardW: CGFloat = (Self.width - 32 - 8) / 2, cardH: CGFloat = 56
        for (i, entry) in cards.enumerated() {
            let col = i % 2, row = i / 2
            let b = LauncherTile(symbol: entry.0, label: entry.1, target: self, action: entry.2)
            b.frame = NSRect(x: 16 + CGFloat(col) * (cardW + 8),
                             y: Self.height - 60 - cardH - CGFloat(row) * (cardH + 8),
                             width: cardW, height: cardH)
            v.addSubview(b)
        }

        let sep = NSBox(frame: NSRect(x: 16, y: 130, width: Self.width - 32, height: 1))
        sep.boxType = .separator
        v.addSubview(sep)

        // Settings as switches: a label on the left, the switch on the right.
        func switchRow(_ title: String, y: CGFloat, on: Bool, action: Selector) -> NSSwitch {
            let l = NSTextField(labelWithString: title)
            l.font = .systemFont(ofSize: 12)
            l.frame = NSRect(x: 16, y: y + 3, width: Self.width - 90, height: 16)
            v.addSubview(l)
            let s = NSSwitch()
            s.controlSize = .small
            s.target = self; s.action = action
            s.state = on ? .on : .off
            s.setAccessibilityLabel(title)
            s.sizeToFit()
            s.setFrameOrigin(NSPoint(x: Self.width - 16 - s.frame.width, y: y))
            v.addSubview(s)
            return s
        }
        defaultCheck = switchRow("Default PDF app", y: 100, on: defaultEnabled, action: #selector(makeDefault))
        loginCheck = switchRow("Open at login", y: 74, on: loginEnabled, action: #selector(toggleLogin))
        shelfCheck = switchRow("Drop shelf while dragging", y: 48, on: shelfEnabled, action: #selector(toggleShelf))

        let quit = NSButton(title: "Quit Jack", target: self, action: #selector(quit))
        quit.bezelStyle = .rounded
        quit.controlSize = .small
        quit.frame = NSRect(x: 14, y: 10, width: 92, height: 26)
        v.addSubview(quit)

        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        updateButton.target = self
        updateButton.action = #selector(openUpdate)
        updateButton.frame = NSRect(x: Self.width - 166, y: 10, width: 150, height: 26)
        updateButton.isHidden = true
        updateButton.bezelColor = Chrome.tint
        v.addSubview(updateButton)

        // The drag-hover state OWNS the moment: frosted glass blurs the whole grid away —
        // the only readable thing is what happens when you let go (Keno's call).
        dropOverlay.frame = v.bounds
        dropOverlay.material = .popover
        dropOverlay.blendingMode = .withinWindow
        dropOverlay.state = .active
        dropOverlay.wantsLayer = true
        dropOverlay.layer?.cornerRadius = 12
        dropOverlay.layer?.borderWidth = 2
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            dropOverlay.layer?.borderColor = Chrome.tint.cgColor
        }
        dropOverlay.layer?.masksToBounds = true
        let dropTitle = NSTextField(labelWithString: "Drop to convert or combine")
        dropTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        dropTitle.alignment = .center
        dropTitle.frame = NSRect(x: 0, y: dropOverlay.bounds.midY + 2,
                                 width: dropOverlay.bounds.width, height: 22)
        dropOverlay.addSubview(dropTitle)
        let dropSub = NSTextField(labelWithString: "Photos combine into one PDF · documents convert · folders batch")
        dropSub.font = .systemFont(ofSize: 11)
        dropSub.textColor = .secondaryLabelColor
        dropSub.alignment = .center
        dropSub.frame = NSRect(x: 8, y: dropOverlay.bounds.midY - 22,
                               width: dropOverlay.bounds.width - 16, height: 16)
        dropOverlay.addSubview(dropSub)
        dropOverlay.isHidden = true
        v.addSubview(dropOverlay)

        self.view = v
    }

    @objc private func newPDF() { onNew?() }
    @objc private func openPDF() { onOpen?() }
    @objc private func makeDefault() {
        // Already default: nothing to do — keep the box checked.
        if defaultEnabled { defaultCheck?.state = .on; return }
        onMakeDefault?()
    }
    @objc private func photos() { onPhotos?() }
    @objc private func sign() { onSign?() }
    @objc private func organize() { onOrganize?() }
    @objc private func batch() { onBatch?() }
    @objc private func toggleLogin() { onToggleLogin?(loginCheck?.state == .on) }
    @objc private func toggleShelf() { onToggleShelf?(shelfCheck?.state == .on) }
    @objc private func quit() { onQuit?() }
    @objc private func openUpdate() {
        if let onUpdate = onUpdate { onUpdate() }                 // Sparkle flow (installs in place)
        else if let u = updateURL { NSWorkspace.shared.open(u) }  // fallback: releases page
    }
}
