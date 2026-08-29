// Reader window: Jack as a full PDF reader — thumbnails, search, zoom, print, lock — with
// Fill & Sign and Organize one click away. This is the window a double-clicked PDF opens into.
import AppKit
import PDFKit

final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    var onFillSign: ((URL) -> Void)?
    var onOrganize: (([URL]) -> Void)?

    private let pdfURL: URL
    private let pdfView = PDFView()
    private let thumbnailView = PDFThumbnailView()
    private let searchField = NSSearchField()
    private let pageLabel = NSTextField(labelWithString: "")
    private let matchLabel = NSTextField(labelWithString: "")

    private var matches: [PDFSelection] = []
    private var matchIndex = 0
    private var sidebarVisible = true
    private let barHeight: CGFloat = 48
    private let sidebarWidth: CGFloat = 168

    init?(pdfURL: URL) {
        guard let doc = PDFDocument(url: pdfURL) else { return nil }
        self.pdfURL = pdfURL
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 780),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = pdfURL.lastPathComponent
        win.center()
        win.setFrameAutosaveName("JackReader")
        super.init(window: win)
        win.delegate = self
        buildUI(doc: doc)
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            AppDelegate.readers.removeAll { $0 === self }
            AppDelegate.updateActivationPolicy()
        }
    }

    // MARK: - UI

    private func buildUI(doc: PDFDocument) {
        guard let content = window?.contentView else { return }

        let bar = NSView(frame: NSRect(x: 0, y: content.bounds.height - barHeight,
                                       width: content.bounds.width, height: barHeight))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.addSubview(bar)

        func tb(_ title: String, _ action: Selector, _ x: CGFloat, _ w: CGFloat, symbol: String? = nil) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.frame = NSRect(x: x, y: 9, width: w, height: 30)
            if let symbol = symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
                img.isTemplate = true
                b.image = img
                b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            }
            bar.addSubview(b)
            return b
        }

        _ = tb("", #selector(toggleSidebar(_:)), 12, 40, symbol: "sidebar.left")

        pageLabel.textColor = .secondaryLabelColor
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pageLabel.alignment = .center
        pageLabel.frame = NSRect(x: 58, y: 15, width: 92, height: 18)
        bar.addSubview(pageLabel)

        _ = tb("−", #selector(zoomOut(_:)), 156, 36)
        _ = tb("＋", #selector(zoomIn(_:)), 196, 36)
        _ = tb("Fit", #selector(zoomToFit(_:)), 236, 44)

        _ = tb("Fill & Sign", #selector(fillAndSign(_:)), 292, 96, symbol: "signature")
        _ = tb("Organize", #selector(organizePages(_:)), 394, 92, symbol: "doc.on.doc")
        _ = tb("Lock…", #selector(lockForSharing(_:)), 492, 78, symbol: "lock")
        _ = tb("Print", #selector(printDocument(_:)), 576, 64)

        // Search cluster, pinned right.
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        matchLabel.alignment = .right
        matchLabel.frame = NSRect(x: content.bounds.width - 434, y: 15, width: 70, height: 18)
        matchLabel.autoresizingMask = [.minXMargin]
        bar.addSubview(matchLabel)

        searchField.placeholderString = "Search"
        searchField.frame = NSRect(x: content.bounds.width - 358, y: 10, width: 260, height: 28)
        searchField.autoresizingMask = [.minXMargin]
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        bar.addSubview(searchField)

        let prev = tb("‹", #selector(previousMatch(_:)), content.bounds.width - 92, 36)
        prev.autoresizingMask = [.minXMargin]
        let next = tb("›", #selector(nextMatch(_:)), content.bounds.width - 52, 36)
        next.autoresizingMask = [.minXMargin]

        // Thumbnail sidebar + main view laid out manually so the toggle is a simple re-frame.
        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 120, height: 120)
        thumbnailView.backgroundColor = NSColor.underPageBackgroundColor
        content.addSubview(thumbnailView)

        pdfView.document = doc
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = NSColor.underPageBackgroundColor
        content.addSubview(pdfView)
        layoutViews()

        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        pageChanged()
    }

    private func layoutViews() {
        guard let content = window?.contentView else { return }
        let h = content.bounds.height - barHeight
        let sw = sidebarVisible ? sidebarWidth : 0
        thumbnailView.frame = NSRect(x: 0, y: 0, width: sw, height: h)
        thumbnailView.isHidden = !sidebarVisible
        thumbnailView.autoresizingMask = [.height]
        pdfView.frame = NSRect(x: sw, y: 0, width: content.bounds.width - sw, height: h)
        pdfView.autoresizingMask = [.width, .height]
    }

    @objc private func pageChanged() {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return }
        pageLabel.stringValue = "\(doc.index(for: page) + 1) of \(doc.pageCount)"
    }

    // MARK: - Menu / toolbar actions (also reached via the responder chain from the main menu)

    @objc func toggleSidebar(_ sender: Any?) {
        sidebarVisible.toggle()
        layoutViews()
    }

    @objc func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc func zoomToFit(_ sender: Any?) { pdfView.autoScales = true }
    @objc func actualSize(_ sender: Any?) { pdfView.scaleFactor = 1.0 }

    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
    }

    @objc func printDocument(_ sender: Any?) {
        guard let window = window, let doc = pdfView.document else { return }
        let info = NSPrintInfo.shared
        if let op = doc.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }

    @objc func fillAndSign(_ sender: Any?) {
        let url = pdfURL
        close()
        onFillSign?(url)
    }

    @objc func organizePages(_ sender: Any?) {
        let url = pdfURL
        close()
        onOrganize?([url])
    }

    // MARK: - Lock for Sharing (password-protect a copy)

    @objc func lockForSharing(_ sender: Any?) {
        guard let doc = pdfView.document, let window = window else { return }

        let alert = NSAlert()
        alert.messageText = "Lock for Sharing"
        alert.informativeText = "Saves a password-protected copy. Anyone with the password can open it; the original file is untouched."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        let pw = NSSecureTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
        pw.placeholderString = "Password"
        let verify = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        verify.placeholderString = "Verify password"
        pw.nextKeyView = verify
        box.addSubview(pw); box.addSubview(verify)
        alert.accessoryView = box
        alert.addButton(withTitle: "Lock…")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = pw

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let password = pw.stringValue
        guard !password.isEmpty else {
            infoAlert("No password", "Enter a password to lock the PDF.")
            return
        }
        guard password == verify.stringValue else {
            infoAlert("Passwords don’t match", "The two password fields must match.")
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = pdfURL.deletingPathExtension().lastPathComponent + "-locked.pdf"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let out = panel.url else { return }
            let options: [PDFDocumentWriteOption: Any] = [
                .userPasswordOption: password,
                .ownerPasswordOption: password
            ]
            if doc.write(to: out, withOptions: options) {
                NSWorkspace.shared.activateFileViewerSelecting([out])
                NSSound(named: "Glass")?.play()
            } else {
                infoAlert("Lock failed", "Couldn’t write the locked PDF.")
            }
        }
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        // Live-clear highlights when the field is emptied; searches run on Enter.
        if searchField.stringValue.isEmpty { clearSearch() }
    }

    @objc private func searchChanged() {
        let term = searchField.stringValue
        guard !term.isEmpty else { clearSearch(); return }
        guard let doc = pdfView.document else { return }
        matches = doc.findString(term, withOptions: [.caseInsensitive])
        matchIndex = 0
        for m in matches { m.color = NSColor.systemYellow.withAlphaComponent(0.6) }
        pdfView.highlightedSelections = matches.isEmpty ? nil : matches
        if matches.isEmpty {
            matchLabel.stringValue = "0 found"
        } else {
            showMatch()
        }
    }

    private func clearSearch() {
        matches = []
        matchIndex = 0
        matchLabel.stringValue = ""
        pdfView.highlightedSelections = nil
        pdfView.setCurrentSelection(nil, animate: false)
    }

    private func showMatch() {
        guard !matches.isEmpty else { return }
        let sel = matches[matchIndex]
        matchLabel.stringValue = "\(matchIndex + 1) of \(matches.count)"
        pdfView.setCurrentSelection(sel, animate: true)
        pdfView.go(to: sel)
    }

    @objc func nextMatch(_ sender: Any?) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + 1) % matches.count
        showMatch()
    }

    @objc func previousMatch(_ sender: Any?) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex - 1 + matches.count) % matches.count
        showMatch()
    }
}
