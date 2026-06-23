// Modal sheet to create or pick a signature: draw it, type it, or reuse a saved one.
// New draw/type signatures are saved to the library so they're available next time.
import AppKit

final class SignatureSheetController: NSObject, NSTextFieldDelegate {
    private var panel: NSWindow!
    private var completion: ((NSImage?) -> Void)?

    private let seg = NSSegmentedControl(labels: ["Draw", "Type", "Saved"], trackingMode: .selectOne, target: nil, action: nil)
    private let drawTab = NSView()
    private let typeTab = NSView()
    private let savedTab = NSView()

    private let capture = SignatureCaptureView()
    private let typeField = NSTextField()
    private let fontPopup = NSPopUpButton()
    private let typePreview = NSTextField(labelWithString: "")

    private var savedURLs: [URL] = []
    private var savedButtons: [NSButton] = []
    private var selectedSavedURL: URL?

    private let cursiveFonts = ["Snell Roundhand", "Savoye LET", "Bradley Hand", "Noteworthy", "Zapfino", "Helvetica Neue"]

    func present(in parent: NSWindow, completion: @escaping (NSImage?) -> Void) {
        self.completion = completion
        buildUI()
        parent.beginSheet(panel) { _ in }
    }

    private func buildUI() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))

        seg.frame = NSRect(x: 20, y: 360, width: 560, height: 26)
        seg.selectedSegment = 0
        seg.target = self
        seg.action = #selector(switchTab)
        content.addSubview(seg)

        let area = NSRect(x: 20, y: 60, width: 560, height: 288)
        for t in [drawTab, typeTab, savedTab] { t.frame = area; content.addSubview(t) }

        buildDrawTab()
        buildTypeTab()
        buildSavedTab()

        let cancel = button("Cancel", #selector(cancel)); cancel.frame = NSRect(x: 356, y: 16, width: 92, height: 30)
        cancel.keyEquivalent = "\u{1b}"
        let use = button("Use Signature", #selector(use)); use.frame = NSRect(x: 456, y: 16, width: 124, height: 30)
        use.keyEquivalent = "\r"
        content.addSubview(cancel); content.addSubview(use)

        panel = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = content
        showTab(0)
    }

    private let drawHint = NSTextField(labelWithString: "")
    private let trackpadToggle = NSButton(checkboxWithTitle: "Glide on trackpad (no click)", target: nil, action: nil)

    private func buildDrawTab() {
        capture.frame = NSRect(x: 0, y: 38, width: 560, height: 250)
        capture.wantsLayer = true
        capture.layer?.borderWidth = 1
        capture.layer?.borderColor = NSColor.separatorColor.cgColor
        capture.layer?.cornerRadius = 8
        drawTab.addSubview(capture)

        let clear = button("Clear", #selector(clearDrawing)); clear.frame = NSRect(x: 0, y: 4, width: 80, height: 26)
        drawTab.addSubview(clear)

        trackpadToggle.frame = NSRect(x: 92, y: 7, width: 220, height: 22)
        trackpadToggle.target = self
        trackpadToggle.action = #selector(toggleTrackpad)
        drawTab.addSubview(trackpadToggle)

        drawHint.textColor = .secondaryLabelColor
        drawHint.font = .systemFont(ofSize: 11)
        drawHint.frame = NSRect(x: 318, y: 9, width: 242, height: 18)
        drawTab.addSubview(drawHint)
        updateDrawHint()
    }

    private func updateDrawHint() {
        drawHint.stringValue = trackpadToggle.state == .on
            ? "Glide one finger on the trackpad — no click."
            : "Draw with your mouse or trackpad (click-drag)."
    }

    @objc private func toggleTrackpad() {
        capture.setTrackpad(trackpadToggle.state == .on)
        updateDrawHint()
    }

    private func buildTypeTab() {
        typeField.frame = NSRect(x: 0, y: 236, width: 560, height: 28)
        typeField.placeholderString = "Type your name"
        typeField.delegate = self
        typeTab.addSubview(typeField)

        fontPopup.frame = NSRect(x: 0, y: 196, width: 240, height: 28)
        for f in cursiveFonts where NSFont(name: f, size: 12) != nil { fontPopup.addItem(withTitle: f) }
        if fontPopup.numberOfItems == 0 { fontPopup.addItem(withTitle: "Helvetica Neue") }
        fontPopup.target = self; fontPopup.action = #selector(updatePreview)
        typeTab.addSubview(fontPopup)

        typePreview.frame = NSRect(x: 0, y: 40, width: 560, height: 140)
        typePreview.alignment = .center
        typePreview.lineBreakMode = .byTruncatingTail
        typeTab.addSubview(typePreview)
        updatePreview()
    }

    private func buildSavedTab() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 38, width: 560, height: 250))
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 250))
        doc.autoresizingMask = [.width]

        savedURLs = SignatureStore.list()
        if savedURLs.isEmpty {
            let empty = NSTextField(labelWithString: "No saved signatures yet — create one in Draw or Type.")
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: 16, y: 110, width: 528, height: 20)
            doc.addSubview(empty)
        } else {
            let cols = 3, w = 170, h = 80, gap = 12
            let rows = (savedURLs.count + cols - 1) / cols
            doc.frame = NSRect(x: 0, y: 0, width: 560, height: max(250, rows * (h + gap) + gap))
            for (i, url) in savedURLs.enumerated() {
                let r = i / cols, c = i % cols
                let x = gap + c * (w + gap)
                let y = Int(doc.frame.height) - gap - (r + 1) * (h) - r * gap
                let b = NSButton(frame: NSRect(x: x, y: y, width: w, height: h))
                b.setButtonType(.pushOnPushOff)
                b.bezelStyle = .regularSquare
                b.imagePosition = .imageOnly
                b.imageScaling = .scaleProportionallyDown
                if let img = SignatureStore.image(at: url) { b.image = thumbnail(img, NSSize(width: w - 12, height: h - 12)) }
                b.tag = i
                b.target = self; b.action = #selector(pickSaved(_:))
                doc.addSubview(b)
                savedButtons.append(b)
            }
        }
        scroll.documentView = doc
        savedTab.addSubview(scroll)

        let del = button("Delete", #selector(deleteSaved)); del.frame = NSRect(x: 0, y: 4, width: 80, height: 26)
        savedTab.addSubview(del)
    }

    // MARK: actions

    @objc private func switchTab() { showTab(seg.selectedSegment) }
    private func showTab(_ i: Int) {
        drawTab.isHidden = i != 0; typeTab.isHidden = i != 1; savedTab.isHidden = i != 2
    }
    @objc private func clearDrawing() { capture.clear() }
    @objc private func updatePreview() {
        let name = fontPopup.titleOfSelectedItem ?? "Helvetica Neue"
        let font = NSFont(name: name, size: 44) ?? NSFont.systemFont(ofSize: 44)
        let text = typeField.stringValue.isEmpty ? "Your name" : typeField.stringValue
        let color = typeField.stringValue.isEmpty ? NSColor.tertiaryLabelColor : NSColor.labelColor
        typePreview.attributedStringValue = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }
    func controlTextDidChange(_ obj: Notification) { updatePreview() }

    @objc private func pickSaved(_ sender: NSButton) {
        for b in savedButtons where b != sender { b.state = .off }
        sender.state = .on
        selectedSavedURL = savedURLs[sender.tag]
    }

    @objc private func deleteSaved() {
        guard let url = selectedSavedURL else { return }
        SignatureStore.delete(url)
        // rebuild the saved tab
        savedTab.subviews.forEach { $0.removeFromSuperview() }
        savedButtons.removeAll(); selectedSavedURL = nil
        buildSavedTab()
    }

    @objc private func cancel() { finish(nil) }

    @objc private func use() {
        var img: NSImage?
        switch seg.selectedSegment {
        case 0:
            img = capture.signatureImage()
            if img == nil { infoAlert("Nothing to use", "Draw your signature first."); return }
            SignatureStore.save(img!)
        case 1:
            img = typedSignatureImage()
            if img == nil { infoAlert("Nothing to use", "Type your name first."); return }
            SignatureStore.save(img!)
        default:
            guard let url = selectedSavedURL, let saved = SignatureStore.image(at: url) else {
                infoAlert("Pick a signature", "Select a saved signature, or create one in Draw or Type."); return
            }
            img = saved
        }
        finish(img)
    }

    private func finish(_ img: NSImage?) {
        if let parent = panel.sheetParent { parent.endSheet(panel) }
        completion?(img)
        completion = nil
    }

    // MARK: helpers

    private func typedSignatureImage() -> NSImage? {
        let text = typeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let name = fontPopup.titleOfSelectedItem ?? "Helvetica Neue"
        let font = NSFont(name: name, size: 72) ?? NSFont.systemFont(ofSize: 72)
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let pad: CGFloat = 20
        let measured = s.size()
        let size = NSSize(width: ceil(measured.width) + pad * 2, height: ceil(measured.height) + pad * 2)
        let img = NSImage(size: size)
        img.lockFocus()
        s.draw(at: NSPoint(x: pad, y: pad))
        img.unlockFocus()
        return img
    }

    private func thumbnail(_ img: NSImage, _ size: NSSize) -> NSImage {
        let t = NSImage(size: size)
        t.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        let scale = min(size.width / max(1, img.size.width), size.height / max(1, img.size.height), 1)
        let w = img.size.width * scale, h = img.size.height * scale
        img.draw(in: NSRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        t.unlockFocus()
        return t
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }
}
