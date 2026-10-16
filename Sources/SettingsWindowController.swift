// Jack ▸ Settings… (⌘,). v3: the first real settings window — the defaults that used to be
// hidden `defaults write` keys or simply fixed. Every change applies to the NEXT document opened.
import AppKit

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let zoomPopup = NSPopUpButton()
    private let thumbsCheck = NSButton(checkboxWithTitle: "Show thumbnails when a document opens", target: nil, action: nil)
    private static let zoomChoices: [(DocumentWindowController.ZoomPolicy, String)] = [
        (.automatic, "Automatic (fit width, never above 100%)"),
        (.fitPage, "Fit Page"),
        (.fitWidth, "Fit Width"),
        (.actual, "Actual Size (100%)")
    ]

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let v = window?.contentView else { return }
        func label(_ t: String, y: CGFloat) {
            let l = NSTextField(labelWithString: t)
            l.font = Chrome.controlFont
            l.alignment = .right
            l.frame = NSRect(x: 20, y: y, width: 130, height: 18)
            v.addSubview(l)
        }
        label("Default zoom:", y: 100)
        zoomPopup.addItems(withTitles: Self.zoomChoices.map { $0.1 })
        let current = DocumentWindowController.defaultZoomPolicy
        zoomPopup.selectItem(at: Self.zoomChoices.firstIndex { $0.0 == current } ?? 0)
        zoomPopup.target = self
        zoomPopup.action = #selector(zoomChanged)
        zoomPopup.frame = NSRect(x: 156, y: 94, width: 284, height: 28)
        v.addSubview(zoomPopup)

        label("Thumbnails:", y: 62)
        thumbsCheck.state = DocumentWindowController.thumbnailsOnOpen ? .on : .off
        thumbsCheck.target = self
        thumbsCheck.action = #selector(thumbsChanged)
        thumbsCheck.frame = NSRect(x: 156, y: 60, width: 290, height: 20)
        v.addSubview(thumbsCheck)

        let note = NSTextField(labelWithString: "Changes apply to documents you open next.")
        note.font = Chrome.metaFont
        note.textColor = .tertiaryLabelColor
        note.frame = NSRect(x: 156, y: 26, width: 290, height: 14)
        v.addSubview(note)
    }

    @objc private func zoomChanged() {
        let i = zoomPopup.indexOfSelectedItem
        guard Self.zoomChoices.indices.contains(i) else { return }
        UserDefaults.standard.set(Self.zoomChoices[i].0.rawValue, forKey: "jack.defaultZoom")
    }
    @objc private func thumbsChanged() {
        UserDefaults.standard.set(thumbsCheck.state == .on, forKey: "jack.thumbnailsOnOpen")
    }

    @objc func show(_ sender: Any?) {
        window?.center()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}
