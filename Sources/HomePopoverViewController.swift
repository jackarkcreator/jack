// The menu bar popover: Jack's compact launcher — a 2×3 action grid, recents, and status.
// v2.8 ratified mock: half the old height, drop-target hint up top, same six actions.
import AppKit

final class HomePopoverViewController: NSViewController {
    var onNew: (() -> Void)?
    var onOpen: (() -> Void)?
    var onPhotos: (() -> Void)?
    var onSign: (() -> Void)?
    var onOrganize: (() -> Void)?
    var onBatch: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?
    var onMakeDefault: (() -> Void)?
    var onQuit: (() -> Void)?
    var onUpdate: (() -> Void)?
    var onToggleLogin: ((Bool) -> Void)?
    var loginEnabled = false { didSet { loginCheck?.state = loginEnabled ? .on : .off } }
    var defaultEnabled = false {
        didSet {
            defaultCheck?.state = defaultEnabled ? .on : .off
            defaultCheck?.title = defaultEnabled ? "Jack is your default PDF app" : "★ Make Jack my default PDF app"
        }
    }
    private var defaultCheck: NSButton?
    private var loginCheck: NSButton?
    private var recentButtons: [NSButton] = []
    private let recentsRow = NSView()
    private let updateButton = NSButton(title: "↓ Update", target: nil, action: nil)
    private var updateURL: URL?

    func showUpdate(version: String, url: URL) {
        updateURL = url
        updateButton.title = "↓ Update to \(version)"
        updateButton.isHidden = false
    }

    private static let width: CGFloat = 312
    private static let height: CGFloat = 352

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))

        let header = NSTextField(labelWithString: "Drop files anywhere to start")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.frame = NSRect(x: 18, y: Self.height - 30, width: Self.width - 36, height: 18)
        v.addSubview(header)

        // 2×3 grid — same six actions as always, mock's short labels.
        let cards: [(String, String, Selector)] = [
            ("doc.badge.plus", "New PDF", #selector(newPDF)),
            ("folder", "Open", #selector(openPDF)),
            ("photo.on.rectangle", "Combine", #selector(photos)),
            ("signature", "Sign", #selector(sign)),
            ("doc.on.doc", "Organize", #selector(organize)),
            ("gearshape.2", "Batch", #selector(batch))
        ]
        let cardW: CGFloat = 134, cardH: CGFloat = 58
        for (i, entry) in cards.enumerated() {
            let col = i % 2, row = i / 2
            let b = NSButton(title: entry.1, target: self, action: entry.2)
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageAbove
            b.font = .systemFont(ofSize: 12, weight: .semibold)
            if let img = NSImage(systemSymbolName: entry.0, accessibilityDescription: entry.1) {
                img.isTemplate = true
                b.image = img.withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
            }
            b.frame = NSRect(x: 16 + CGFloat(col) * (cardW + 12),
                             y: Self.height - 100 - CGFloat(row) * (cardH + 8),
                             width: cardW, height: cardH)
            v.addSubview(b)
        }

        // Recents — the two most recent documents, clickable; refreshed on every show.
        recentsRow.frame = NSRect(x: 18, y: Self.height - 325, width: Self.width - 36, height: 20)
        v.addSubview(recentsRow)
        refreshRecents()

        let sep = NSBox(frame: NSRect(x: 16, y: 96, width: Self.width - 32, height: 1))
        sep.boxType = .separator
        v.addSubview(sep)

        let def = NSButton(checkboxWithTitle: "★ Make Jack my default PDF app", target: self, action: #selector(makeDefault))
        def.font = .systemFont(ofSize: 11)
        def.frame = NSRect(x: 16, y: 68, width: Self.width - 32, height: 20)
        def.state = defaultEnabled ? .on : .off
        if defaultEnabled { def.title = "Jack is your default PDF app" }
        v.addSubview(def)
        defaultCheck = def

        let chk = NSButton(checkboxWithTitle: "Open Jack at login", target: self, action: #selector(toggleLogin))
        chk.font = .systemFont(ofSize: 11)
        chk.frame = NSRect(x: 16, y: 44, width: Self.width - 32, height: 20)
        chk.state = loginEnabled ? .on : .off
        v.addSubview(chk)
        loginCheck = chk

        let quit = NSButton(title: "Quit Jack", target: self, action: #selector(quit))
        quit.bezelStyle = .rounded
        quit.controlSize = .small
        quit.frame = NSRect(x: 16, y: 8, width: 92, height: 26)
        v.addSubview(quit)

        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        updateButton.target = self
        updateButton.action = #selector(openUpdate)
        updateButton.frame = NSRect(x: Self.width - 166, y: 8, width: 150, height: 26)
        updateButton.isHidden = true
        updateButton.contentTintColor = .controlAccentColor
        v.addSubview(updateButton)

        self.view = v
    }

    func refreshRecents() {
        guard isViewLoaded else { return }
        recentsRow.subviews.forEach { $0.removeFromSuperview() }
        recentButtons = []
        let recents = RecentDocuments.list().prefix(2)
        var rx: CGFloat = 0
        let rLabel = NSTextField(labelWithString: "Recent:")
        rLabel.font = .systemFont(ofSize: 11)
        rLabel.textColor = .secondaryLabelColor
        rLabel.frame = NSRect(x: rx, y: 3, width: 46, height: 15)
        recentsRow.addSubview(rLabel)
        rx += 48
        if recents.isEmpty {
            let none = NSTextField(labelWithString: "nothing yet")
            none.font = .systemFont(ofSize: 11)
            none.textColor = .tertiaryLabelColor
            none.frame = NSRect(x: rx, y: 3, width: 120, height: 15)
            recentsRow.addSubview(none)
        }
        for url in recents {
            let b = NSButton(title: url.deletingPathExtension().lastPathComponent, target: self, action: #selector(openRecent(_:)))
            b.isBordered = false
            b.font = .systemFont(ofSize: 11)
            b.contentTintColor = .controlAccentColor
            let w = min(110, b.intrinsicContentSize.width)
            b.frame = NSRect(x: rx, y: 0, width: w, height: 20)
            b.toolTip = url.path
            recentButtons.append(b)
            recentsRow.addSubview(b)
            rx += w + 8
        }
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
    @objc private func openRecent(_ sender: NSButton) {
        if let path = sender.toolTip { onOpenRecent?(URL(fileURLWithPath: path)) }
    }
    @objc private func toggleLogin() { onToggleLogin?(loginCheck?.state == .on) }
    @objc private func quit() { onQuit?() }
    @objc private func openUpdate() {
        if let onUpdate = onUpdate { onUpdate() }                 // Sparkle flow (installs in place)
        else if let u = updateURL { NSWorkspace.shared.open(u) }  // fallback: releases page
    }
}
