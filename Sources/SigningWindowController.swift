// The PDF signing window: open a PDF, add a signature, drag/resize it, save a flattened signed PDF.
import AppKit
import PDFKit

final class SigningWindowController: NSWindowController {
    private let pdfURL: URL
    private let pdfView = SigningPDFView()
    private weak var selected: ImageStampAnnotation?

    private let sizeSlider = NSSlider()
    private let removeButton = NSButton()

    private var sheet: SignatureSheetController?

    init?(pdfURL: URL) {
        guard let doc = PDFDocument(url: pdfURL) else { return nil }
        self.pdfURL = pdfURL
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Jack — \(pdfURL.lastPathComponent)"
        win.center()
        super.init(window: win)
        buildUI(doc: doc)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(doc: PDFDocument) {
        guard let content = window?.contentView else { return }

        let barHeight: CGFloat = 48
        let bar = NSView(frame: NSRect(x: 0, y: content.bounds.height - barHeight, width: content.bounds.width, height: barHeight))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.addSubview(bar)

        let add = NSButton(title: "Add Signature", target: self, action: #selector(addSignature))
        add.bezelStyle = .rounded
        add.frame = NSRect(x: 16, y: 9, width: 120, height: 30)
        bar.addSubview(add)

        let addText = NSButton(title: "Add Text", target: self, action: #selector(self.addText))
        addText.bezelStyle = .rounded
        addText.frame = NSRect(x: 142, y: 9, width: 86, height: 30)
        bar.addSubview(addText)

        let sizeLabel = NSTextField(labelWithString: "Size")
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.frame = NSRect(x: 240, y: 15, width: 32, height: 18)
        bar.addSubview(sizeLabel)

        sizeSlider.frame = NSRect(x: 274, y: 12, width: 140, height: 24)
        sizeSlider.minValue = 60; sizeSlider.maxValue = 600
        sizeSlider.target = self; sizeSlider.action = #selector(resizeSelected)
        sizeSlider.isEnabled = false
        bar.addSubview(sizeSlider)

        removeButton.title = "Remove"
        removeButton.bezelStyle = .rounded
        removeButton.target = self; removeButton.action = #selector(removeSelected)
        removeButton.frame = NSRect(x: 424, y: 9, width: 84, height: 30)
        removeButton.isEnabled = false
        bar.addSubview(removeButton)

        if hasFormFields(doc) {
            let hint = NSTextField(labelWithString: "Fillable form — click a field to type")
            hint.textColor = .secondaryLabelColor
            hint.font = .systemFont(ofSize: 11)
            hint.frame = NSRect(x: content.bounds.width - 420, y: 15, width: 230, height: 18)
            hint.alignment = .right
            hint.autoresizingMask = [.minXMargin]
            bar.addSubview(hint)
        }

        let save = NSButton(title: "Save PDF…", target: self, action: #selector(saveSigned))
        save.bezelStyle = .rounded
        save.keyEquivalent = "s"
        save.frame = NSRect(x: content.bounds.width - 150, y: 9, width: 134, height: 30)
        save.autoresizingMask = [.minXMargin]
        bar.addSubview(save)

        pdfView.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - barHeight)
        pdfView.autoresizingMask = [.width, .height]
        pdfView.document = doc
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = NSColor.underPageBackgroundColor
        pdfView.stampDelegate = self
        content.addSubview(pdfView)
    }

    @objc private func addSignature() {
        guard let window = window else { return }
        let s = SignatureSheetController()
        sheet = s
        s.present(in: window) { [weak self] image in
            self?.sheet = nil
            guard let self = self, let image = image else { return }
            self.place(image)
        }
    }

    private func place(_ image: NSImage) {
        guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return }
        let box = page.bounds(for: .mediaBox)
        let width = min(220, box.width * 0.4)
        let aspect = image.size.height <= 0 ? 1 : image.size.width / image.size.height
        let height = width / max(0.01, aspect)
        let origin = CGPoint(x: box.midX - width / 2, y: box.midY - height / 2)
        let ann = ImageStampAnnotation(image: image, bounds: CGRect(x: origin.x, y: origin.y, width: width, height: height))
        page.addAnnotation(ann)
        didSelect(ann)
        pdfView.needsDisplay = true
    }

    // Add Text: type a string, place it like a signature (drag/resize/remove, then flatten).
    @objc private func addText() {
        let alert = NSAlert()
        alert.messageText = "Add text"
        alert.informativeText = "Type the text to place on the page. You can drag and resize it after."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let img = textImage(text) else { return }
        place(img)
    }

    private func textImage(_ text: String) -> NSImage? {
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 48),
            .foregroundColor: NSColor.black
        ])
        let pad: CGFloat = 12
        let m = s.size()
        let size = NSSize(width: ceil(m.width) + pad * 2, height: ceil(m.height) + pad * 2)
        let img = NSImage(size: size)
        img.lockFocus()
        s.draw(at: NSPoint(x: pad, y: pad))
        img.unlockFocus()
        return img
    }

    private func hasFormFields(_ doc: PDFDocument) -> Bool {
        for i in 0..<doc.pageCount {
            if let p = doc.page(at: i), p.annotations.contains(where: { $0.type == "Widget" }) { return true }
        }
        return false
    }

    // Called by SigningPDFView when an annotation is clicked.
    func didSelect(_ ann: ImageStampAnnotation?) {
        if selected !== ann { selected?.outline = false }
        selected = ann
        ann?.outline = true
        if let ann = ann { sizeSlider.doubleValue = Double(ann.bounds.width) }
        refreshControls()
        pdfView.needsDisplay = true
    }

    private func refreshControls() {
        let on = selected != nil
        sizeSlider.isEnabled = on
        removeButton.isEnabled = on
    }

    // The most-recently-added signature across all pages (fallback when nothing is clicked).
    private func lastStamp() -> ImageStampAnnotation? {
        guard let doc = pdfView.document else { return nil }
        for i in stride(from: doc.pageCount - 1, through: 0, by: -1) {
            if let s = doc.page(at: i)?.annotations.compactMap({ $0 as? ImageStampAnnotation }).last { return s }
        }
        return nil
    }

    @objc private func resizeSelected() {
        guard let ann = selected ?? lastStamp() else { return }
        let newW = CGFloat(sizeSlider.doubleValue)
        let newH = newW / max(0.01, ann.aspect)
        let cx = ann.bounds.midX, cy = ann.bounds.midY
        ann.bounds = CGRect(x: cx - newW / 2, y: cy - newH / 2, width: newW, height: newH)
        pdfView.needsDisplay = true
    }

    @discardableResult
    private func removeStamp(_ ann: ImageStampAnnotation) -> Bool {
        if let p = ann.page, p.annotations.contains(ann) { p.removeAnnotation(ann); return true }
        guard let doc = pdfView.document else { return false }
        for i in 0..<doc.pageCount {
            if let p = doc.page(at: i), p.annotations.contains(ann) { p.removeAnnotation(ann); return true }
        }
        return false
    }

    // PDFView caches page renders; reassigning the same document forces a full re-render.
    private func forceRefresh() {
        let page = pdfView.currentPage
        let doc = pdfView.document
        pdfView.document = nil
        pdfView.document = doc
        if let page = page { pdfView.go(to: page) }
    }

    @objc private func removeSelected() {
        guard let ann = selected ?? lastStamp() else { return }
        removeStamp(ann)
        selected = nil
        forceRefresh()           // PDFView caches the page render; force a clean repaint
        didSelect(lastStamp())   // select the next remaining signature, if any
    }

    @objc private func saveSigned() {
        guard let doc = pdfView.document, let window = window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = pdfURL.deletingPathExtension().lastPathComponent + "-signed.pdf"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let out = panel.url, let self = self else { return }
            if self.flatten(doc, to: out) {
                NSWorkspace.shared.activateFileViewerSelecting([out])
                NSSound(named: "Glass")?.play()
            } else {
                infoAlert("Save failed", "Couldn’t write the signed PDF.")
            }
        }
    }

    // Burn the signature(s) into the page content so the result renders everywhere and can't be moved.
    private func flatten(_ doc: PDFDocument, to url: URL) -> Bool {
        guard let firstPage = doc.page(at: 0) else { return false }
        var firstBox = firstPage.bounds(for: .mediaBox)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return false }

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)

            let stamps = page.annotations.compactMap { $0 as? ImageStampAnnotation }
            stamps.forEach { page.removeAnnotation($0) }

            ctx.saveGState()
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()

            for s in stamps {
                if let cg = s.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    ctx.saveGState()
                    ctx.interpolationQuality = .high
                    ctx.draw(cg, in: s.bounds)
                    ctx.restoreGState()
                }
                page.addAnnotation(s) // keep the in-memory doc intact
            }

            ctx.endPDFPage()
        }
        ctx.closePDF()
        return true
    }
}
