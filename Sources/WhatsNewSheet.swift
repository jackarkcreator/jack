// "What's new in Jack 3": shown ONCE per version, over the first document opened after an
// update, and any time from Help ▸ What's New in Jack. A redesign that lands with no word
// of explanation feels like it landed all at once; four lines fix that. (3.1 mock, E4.)
import AppKit

enum WhatsNew {
    /// Bump when the sheet's content changes; each value shows once per Mac.
    static let version = "3.1"
    private static let seenKey = "jack.whatsNewSeen"
    private static var shownThisRun = false

    static var shouldShowAutomatically: Bool {
        !shownThisRun && UserDefaults.standard.string(forKey: seenKey) != version
    }

    static func markShown() {
        shownThisRun = true
        UserDefaults.standard.set(version, forKey: seenKey)
    }

    private static let items: [(symbol: String, title: String, text: String)] = [
        ("rectangle.split.1x2", "Two rows, two jobs",
         "The top row is your document: name, status, Share, Save. The row below is your work: Read, Markup or Redact and their tools."),
        ("plus.magnifyingglass", "Opens at a real size",
         "Pages open at 100% or smaller. Change zoom and layout from the pill at the bottom."),
        ("highlighter", "Tools stay on",
         "Pick Highlight and every selection is marked. Keys V T H U S N, and Esc to put a tool down."),
        ("square.and.arrow.down", "Save lights up when there\u{2019}s work",
         "Your original stays as it is until you save. Share now offers clean and locked copies too.")
    ]

    /// Builds the sheet window; `onClose` runs when Continue is pressed.
    static func makeSheet(onClose: @escaping () -> Void) -> NSWindow {
        let W: CGFloat = 470, pad: CGFloat = 30
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 500),
                           styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        let v = win.contentView!
        var y: CGFloat = 26   // top-down

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        let iconFrameTop = y
        v.addSubview(icon)
        y += 60 + 10
        let title = NSTextField(labelWithString: "What\u{2019}s new in Jack 3")
        title.font = .systemFont(ofSize: 20, weight: .heavy)
        title.alignment = .center
        v.addSubview(title)
        let titleTop = y
        y += 26 + 2
        let sub = NSTextField(labelWithString: "A calmer window, with every tool in a predictable place.")
        sub.font = .systemFont(ofSize: 12.5)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        v.addSubview(sub)
        let subTop = y
        y += 18 + 18

        var rowFrames: [(NSView, NSTextField, NSTextField, CGFloat, CGFloat)] = []
        for item in items {
            let tile = NSImageView(image: tinted(Chrome.symbol([item.symbol], item.title, .init(pointSize: 16, weight: .medium)) ?? NSImage(), Chrome.tint))
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 9
            tile.imageAlignment = .alignCenter
            v.addSubview(tile)
            let t = NSTextField(labelWithString: item.title)
            t.font = .systemFont(ofSize: 13.5, weight: .semibold)
            v.addSubview(t)
            let d = NSTextField(wrappingLabelWithString: item.text)
            d.font = .systemFont(ofSize: 12.5)
            d.textColor = .secondaryLabelColor
            d.preferredMaxLayoutWidth = W - pad * 2 - 46
            v.addSubview(d)
            let dh = ceil(d.intrinsicContentSize.height)
            rowFrames.append((tile, t, d, y, dh))
            y += max(34, 18 + dh) + 14
        }
        y += 4
        let link = NSButton(title: "See everything that changed", target: LinkOpener.shared, action: #selector(LinkOpener.openReleases))
        link.isBordered = false
        link.contentTintColor = Chrome.tint
        link.font = .systemFont(ofSize: 12)
        v.addSubview(link)
        let cont = NSButton(title: "Continue", target: nil, action: nil)
        cont.bezelStyle = .rounded
        cont.keyEquivalent = "\r"
        cont.bezelColor = Chrome.tint
        ControlAction.bind(cont) { _ in onClose() }
        v.addSubview(cont)
        let footTop = y
        let H = y + 28 + 22
        win.setContentSize(NSSize(width: W, height: H))
        func flip(_ top: CGFloat, _ h: CGFloat) -> CGFloat { H - top - h }

        icon.frame = NSRect(x: (W - 60) / 2, y: flip(iconFrameTop, 60), width: 60, height: 60)
        title.frame = NSRect(x: pad, y: flip(titleTop, 26), width: W - pad * 2, height: 26)
        sub.frame = NSRect(x: pad, y: flip(subTop, 18), width: W - pad * 2, height: 18)
        for (tile, t, d, top, dh) in rowFrames {
            tile.frame = NSRect(x: pad, y: flip(top, 34), width: 34, height: 34)
            tile.effectiveAppearance.performAsCurrentDrawingAppearance { tile.layer?.backgroundColor = Chrome.tintSoft.cgColor }
            t.frame = NSRect(x: pad + 46, y: flip(top, 18), width: W - pad * 2 - 46, height: 18)
            d.frame = NSRect(x: pad + 46, y: flip(top + 19, dh), width: W - pad * 2 - 46, height: dh)
        }
        cont.sizeToFit()
        let cw = max(cont.frame.width + 12, 96)
        cont.frame = NSRect(x: W - pad - cw, y: flip(footTop, 28), width: cw, height: 28)
        link.sizeToFit()
        link.frame = NSRect(x: pad - 2, y: flip(footTop, 28) + (28 - link.frame.height) / 2, width: link.frame.width, height: link.frame.height)
        win.defaultButtonCell = cont.cell as? NSButtonCell
        return win
    }
}

final class LinkOpener: NSObject {
    static let shared = LinkOpener()
    @objc func openReleases() {
        if let u = URL(string: "https://github.com/jackarkcreator/jack/releases") { NSWorkspace.shared.open(u) }
    }
}
