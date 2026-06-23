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
        add.frame = NSRect(x: 16, y: 9, width: 130, height: 30)
        bar.addSubview(add)

        let sizeLabel = NSTextField(labelWithString: "Size")
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.frame = NSRect(x: 162, y: 15, width: 32, height: 18)
        bar.addSubview(sizeLabel)

        sizeSlider.frame = NSRect(x: 196, y: 12, width: 180, height: 24)
        sizeSlider.minValue = 60; sizeSlider.maxValue = 600
        sizeSlider.target = self; sizeSlider.action = #selector(resizeSelected)
        sizeSlider.isEnabled = false
        bar.addSubview(sizeSlider)

        removeButton.title = "Remove"
        removeButton.bezelStyle = .rounded
        removeButton.target = self; removeButton.action = #selector(removeSelected)
        removeButton.frame = NSRect(x: 388, y: 9, width: 90, height: 30)
        removeButton.isEnabled = false
        bar.addSubview(removeButton)

        let save = NSButton(title: "Save Signed PDF…", target: self, action: #selector(saveSigned))
        save.bezelStyle = .rounded
        save.keyEquivalent = "s"
        save.frame = NSRect(x: content.bounds.width - 176, y: 9, width: 160, height: 30)
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

    // Called by SigningPDFView when an annotation is clicked (or deselected with nil).
    func didSelect(_ ann: ImageStampAnnotation?) {
        selected = ann
        let on = ann != nil
        sizeSlider.isEnabled = on
        removeButton.isEnabled = on
        if let ann = ann { sizeSlider.doubleValue = Double(ann.bounds.width) }
    }

    @objc private func resizeSelected() {
        guard let ann = selected else { return }
        let newW = CGFloat(sizeSlider.doubleValue)
        let newH = newW / max(0.01, ann.aspect)
        let cx = ann.bounds.midX, cy = ann.bounds.midY
        ann.bounds = CGRect(x: cx - newW / 2, y: cy - newH / 2, width: newW, height: newH)
        pdfView.needsDisplay = true
    }

    @objc private func removeSelected() {
        guard let ann = selected, let page = ann.page else { return }
        page.removeAnnotation(ann)
        didSelect(nil)
        pdfView.needsDisplay = true
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
