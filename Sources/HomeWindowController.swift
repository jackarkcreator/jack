// Jack's home window: the hub shown on empty launch. Three actions + drop anywhere.
import AppKit

private final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { isPDFURL($0) || isImageURL($0) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(sender).isEmpty ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let u = urls(sender)
        guard !u.isEmpty else { return false }
        onDrop?(u)
        return true
    }
}

final class HomeWindowController: NSWindowController {
    var onPhotos: (() -> Void)?
    var onSign: (() -> Void)?
    var onOrganize: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 392),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Jack"
        win.center()
        super.init(window: win)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let drop = DropView(frame: NSRect(x: 0, y: 0, width: 520, height: 392))
        drop.onDrop = { [weak self] in self?.onDrop?($0) }
        window?.contentView = drop

        let title = NSTextField(labelWithString: "Jack")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.frame = NSRect(x: 30, y: 336, width: 460, height: 34)
        drop.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Lightweight PDF tools")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.frame = NSRect(x: 30, y: 314, width: 460, height: 18)
        drop.addSubview(subtitle)

        let cards: [(String, String, Selector)] = [
            ("photo.on.rectangle", "Combine Photos → PDF", #selector(combine)),
            ("signature", "Sign a PDF", #selector(sign)),
            ("doc.on.doc", "Organize / Merge Pages", #selector(organize))
        ]
        var y = 226
        for (symbol, label, action) in cards {
            drop.addSubview(card(symbol: symbol, label: label, action: action, y: y))
            y -= 76
        }

        let hint = NSTextField(labelWithString: "Tip: you can also drop photos or PDFs onto this window, or onto Jack in the Dock.")
        hint.textColor = .tertiaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.alignment = .center
        hint.frame = NSRect(x: 20, y: 16, width: 480, height: 16)
        drop.addSubview(hint)
    }

    private func card(symbol: String, label: String, action: Selector, y: Int) -> NSButton {
        let b = NSButton(title: "  " + label, target: self, action: action)
        b.bezelStyle = .regularSquare
        b.frame = NSRect(x: 30, y: CGFloat(y), width: 460, height: 64)
        b.imagePosition = .imageLeading
        b.alignment = .left
        b.font = .systemFont(ofSize: 15, weight: .medium)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            img.isTemplate = true
            b.image = img.withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
            b.imageScaling = .scaleProportionallyDown
        }
        return b
    }

    @objc private func combine() { onPhotos?() }
    @objc private func sign() { onSign?() }
    @objc private func organize() { onOrganize?() }
}
