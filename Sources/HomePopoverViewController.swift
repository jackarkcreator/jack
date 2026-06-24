// The menu bar popover: Jack's compact launcher — three actions, login toggle, quit.
import AppKit

final class HomePopoverViewController: NSViewController {
    var onPhotos: (() -> Void)?
    var onSign: (() -> Void)?
    var onOrganize: (() -> Void)?
    var onQuit: (() -> Void)?
    var onToggleLogin: ((Bool) -> Void)?
    var loginEnabled = false { didSet { loginCheck?.state = loginEnabled ? .on : .off } }

    private var loginCheck: NSButton?
    private let updateButton = NSButton(title: "↓ Update", target: nil, action: nil)
    private var updateURL: URL?

    func showUpdate(version: String, url: URL) {
        updateURL = url
        updateButton.title = "↓ Update to \(version)"
        updateButton.isHidden = false
    }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 392))

        let title = NSTextField(labelWithString: "Jack")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: 20, y: 352, width: 260, height: 26)
        v.addSubview(title)

        let sub = NSTextField(labelWithString: "Lightweight PDF tools")
        sub.textColor = .secondaryLabelColor
        sub.font = .systemFont(ofSize: 12)
        sub.frame = NSRect(x: 20, y: 332, width: 260, height: 16)
        v.addSubview(sub)

        let cards: [(String, String, Selector)] = [
            ("photo.on.rectangle", "Combine Photos → PDF", #selector(photos)),
            ("signature", "Fill & Sign a PDF", #selector(sign)),
            ("doc.on.doc", "Organize / Merge Pages", #selector(organize))
        ]
        var y = 262
        for (symbol, label, action) in cards { v.addSubview(card(symbol, label, action, y)); y -= 60 }

        let sep = NSBox(frame: NSRect(x: 16, y: 96, width: 268, height: 1))
        sep.boxType = .separator
        v.addSubview(sep)

        let chk = NSButton(checkboxWithTitle: "Open Jack at login", target: self, action: #selector(toggleLogin))
        chk.frame = NSRect(x: 20, y: 64, width: 260, height: 20)
        chk.state = loginEnabled ? .on : .off
        v.addSubview(chk)
        loginCheck = chk

        let tip = NSTextField(wrappingLabelWithString: "Tip: drop photos or PDFs onto the menu bar icon, or right-click a file → Open With → Jack.")
        tip.textColor = .tertiaryLabelColor
        tip.font = .systemFont(ofSize: 10)
        tip.frame = NSRect(x: 20, y: 34, width: 260, height: 30)
        v.addSubview(tip)

        let quit = NSButton(title: "Quit Jack", target: self, action: #selector(quit))
        quit.bezelStyle = .rounded
        quit.frame = NSRect(x: 20, y: 6, width: 100, height: 26)
        v.addSubview(quit)

        updateButton.bezelStyle = .rounded
        updateButton.target = self
        updateButton.action = #selector(openUpdate)
        updateButton.frame = NSRect(x: 130, y: 6, width: 150, height: 26)
        updateButton.isHidden = true
        updateButton.contentTintColor = .controlAccentColor
        v.addSubview(updateButton)

        self.view = v
    }

    private func card(_ symbol: String, _ label: String, _ action: Selector, _ y: Int) -> NSButton {
        let b = NSButton(title: "  " + label, target: self, action: action)
        b.bezelStyle = .regularSquare
        b.frame = NSRect(x: 20, y: CGFloat(y), width: 260, height: 50)
        b.imagePosition = .imageLeading
        b.alignment = .left
        b.font = .systemFont(ofSize: 14, weight: .medium)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            img.isTemplate = true
            b.image = img.withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            b.imageScaling = .scaleProportionallyDown
        }
        return b
    }

    @objc private func photos() { onPhotos?() }
    @objc private func sign() { onSign?() }
    @objc private func organize() { onOrganize?() }
    @objc private func toggleLogin() { onToggleLogin?(loginCheck?.state == .on) }
    @objc private func quit() { onQuit?() }
    @objc private func openUpdate() { if let u = updateURL { NSWorkspace.shared.open(u) } }
}
