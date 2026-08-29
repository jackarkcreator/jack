// The document window: one window per PDF, Preview-style. Native unified toolbar (sidebar,
// zoom, Markup, Lock, Print, search, Save), a Markup tool strip that slides in beneath the
// title bar, and a sidebar that is the page organizer. No secondary windows, no "Home".
import AppKit
import PDFKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                      StampSelectionDelegate, PageSidebarDelegate, NSSearchFieldDelegate {

    private let pdfURL: URL
    private let pdfView = SigningPDFView()
    private let sidebar = PageSidebarController()
    private var searchField: NSSearchField?
    private weak var selected: ImageStampAnnotation?
    private var sheet: SignatureSheetController?

    private let docUndo = UndoManager()
    private var sliderStartBounds: CGRect?   // resize gesture start, so one drag = one undo step

    private var matches: [PDFSelection] = []
    private var matchIndex = 0
    private var sidebarVisible = true
    private var markupOn = false
    private let sidebarWidth: CGFloat = 172

    // Markup strip controls
    private var markupAccessory: NSTitlebarAccessoryViewController?
    private let sizeSlider = NSSlider()
    private let removeButton = NSButton()
    private var markupButton: NSButton?

    // Redact strip controls
    private var redactOn = false
    private var redactAccessory: NSTitlebarAccessoryViewController?
    private var redactButton: NSButton?
    private let redactCountLabel = NSTextField(labelWithString: "")
    private let redactTermField = NSTextField()
    private var redactedTerms: Set<String> = []   // fed to the verify pass as forbidden terms

    init?(pdfURL: URL, startInMarkup: Bool = false) {
        guard let doc = PDFDocument(url: pdfURL) else { return nil }
        self.pdfURL = pdfURL
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = pdfURL.lastPathComponent
        win.representedURL = pdfURL            // title-bar proxy icon: drag the file, ⌘-click the path
        win.center()
        win.setFrameAutosaveName("JackDocument")
        super.init(window: win)
        win.delegate = self
        buildUI(doc: doc)
        if startInMarkup { DispatchQueue.main.async { [weak self] in self?.setMarkup(on: true) } }
    }

    required init?(coder: NSCoder) { fatalError() }

    // ⌘Z / Edit menu / toolbar Undo all resolve here through the window.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { docUndo }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            AppDelegate.documents.removeAll { $0 === self }
            AppDelegate.updateActivationPolicy()
        }
    }

    // MARK: - Layout

    private func buildUI(doc: PDFDocument) {
        guard let window = window, let content = window.contentView else { return }

        let toolbar = NSToolbar(identifier: "JackDocToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        if #available(macOS 11.0, *) { window.toolbarStyle = .unified }

        sidebar.document = doc
        sidebar.delegate = self
        sidebar.undoProvider = { [weak self] in self?.docUndo }
        content.addSubview(sidebar.scrollView)

        pdfView.document = doc
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = NSColor.underPageBackgroundColor
        pdfView.stampDelegate = self
        content.addSubview(pdfView)
        layoutViews()

        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        sidebar.reload()
        pageChanged()
    }

    private func layoutViews() {
        guard let content = window?.contentView else { return }
        let sw = sidebarVisible ? sidebarWidth : 0
        sidebar.scrollView.frame = NSRect(x: 0, y: 0, width: sw, height: content.bounds.height)
        sidebar.scrollView.isHidden = !sidebarVisible
        sidebar.scrollView.autoresizingMask = [.height]
        pdfView.frame = NSRect(x: sw, y: 0, width: content.bounds.width - sw, height: content.bounds.height)
        pdfView.autoresizingMask = [.width, .height]
    }

    @objc private func pageChanged() {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return }
        let index = doc.index(for: page)
        setSubtitle("Page \(index + 1) of \(doc.pageCount)")
        sidebar.highlight(pageIndex: index)
    }

    private func setSubtitle(_ s: String) {
        if #available(macOS 11.0, *) { window?.subtitle = s }
    }

    // MARK: - Toolbar

    private enum ItemID {
        static let undo = NSToolbarItem.Identifier("jack.undo")
        static let redo = NSToolbarItem.Identifier("jack.redo")
        static let sidebar = NSToolbarItem.Identifier("jack.sidebar")
        static let zoomOut = NSToolbarItem.Identifier("jack.zoomOut")
        static let zoomIn = NSToolbarItem.Identifier("jack.zoomIn")
        static let markup = NSToolbarItem.Identifier("jack.markup")
        static let redact = NSToolbarItem.Identifier("jack.redact")
        static let clean = NSToolbarItem.Identifier("jack.clean")
        static let lock = NSToolbarItem.Identifier("jack.lock")
        static let print = NSToolbarItem.Identifier("jack.print")
        static let save = NSToolbarItem.Identifier("jack.save")
        static let search = NSToolbarItem.Identifier("jack.search")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.sidebar, .space, ItemID.undo, ItemID.redo, .flexibleSpace, ItemID.zoomOut, ItemID.zoomIn, .space,
         ItemID.markup, ItemID.redact, ItemID.clean, ItemID.lock, ItemID.print, .flexibleSpace, ItemID.search, ItemID.save]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func simple(_ id: NSToolbarItem.Identifier, _ symbol: String, _ label: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }
        switch id {
        case ItemID.sidebar: return simple(id, "sidebar.left", "Thumbnails", #selector(toggleSidebar(_:)))
        case ItemID.undo:    return simple(id, "arrow.uturn.backward", "Undo", #selector(undoEdit(_:)))
        case ItemID.redo:    return simple(id, "arrow.uturn.forward", "Redo", #selector(redoEdit(_:)))
        case ItemID.zoomOut: return simple(id, "minus.magnifyingglass", "Zoom Out", #selector(zoomOut(_:)))
        case ItemID.zoomIn:  return simple(id, "plus.magnifyingglass", "Zoom In", #selector(zoomIn(_:)))
        case ItemID.lock:    return simple(id, "lock", "Lock for Sharing", #selector(lockForSharing(_:)))
        case ItemID.clean:   return simple(id, "sparkles", "Clean for Sharing", #selector(cleanForSharing(_:)))
        case ItemID.redact:
            let item = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(image: NSImage(systemSymbolName: "rectangle.slash",
                                            accessibilityDescription: "Redact") ?? NSImage(),
                             target: self, action: #selector(toggleRedact(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .texturedRounded
            redactButton = b
            item.view = b
            item.label = "Redact"
            item.toolTip = "Redact — permanently remove content"
            return item
        case ItemID.print:   return simple(id, "printer", "Print", #selector(printDocument(_:)))
        case ItemID.markup:
            let item = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(image: NSImage(systemSymbolName: "pencil.tip.crop.circle",
                                            accessibilityDescription: "Markup") ?? NSImage(),
                             target: self, action: #selector(toggleMarkup(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .texturedRounded
            markupButton = b
            item.view = b
            item.label = "Markup"
            item.toolTip = "Fill & Sign"
            return item
        case ItemID.save:
            let item = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(title: "Save PDF…", target: self, action: #selector(saveDocument(_:)))
            b.bezelStyle = .texturedRounded
            item.view = b
            item.label = "Save"
            item.toolTip = "Save a copy with your edits (original stays untouched)"
            return item
        case ItemID.search:
            if #available(macOS 11.0, *) {
                let item = NSSearchToolbarItem(itemIdentifier: id)
                item.searchField.placeholderString = "Search"
                item.searchField.target = self
                item.searchField.action = #selector(searchChanged)
                item.searchField.delegate = self
                item.searchField.sendsWholeSearchString = true
                item.preferredWidthForSearchField = 200
                searchField = item.searchField
                return item
            }
            return nil
        default: return nil
        }
    }

    // MARK: - View actions

    @objc func toggleSidebar(_ sender: Any?) { sidebarVisible.toggle(); layoutViews() }
    @objc func undoEdit(_ sender: Any?) { docUndo.undo() }
    @objc func redoEdit(_ sender: Any?) { docUndo.redo() }
    @objc func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc func zoomToFit(_ sender: Any?) { pdfView.autoScales = true }
    @objc func actualSize(_ sender: Any?) { pdfView.scaleFactor = 1.0 }
    @objc func focusSearch(_ sender: Any?) { if let f = searchField { window?.makeFirstResponder(f) } }

    @objc func printDocument(_ sender: Any?) {
        guard let window = window, let doc = pdfView.document else { return }
        if let op = doc.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true) {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }

    // MARK: - Markup mode (the old signing window, as an in-window tool strip)

    @objc func toggleMarkup(_ sender: Any?) { setMarkup(on: !markupOn) }

    private func setMarkup(on: Bool) {
        guard markupOn != on, let window = window else { return }
        if on { setRedact(on: false) }   // one tool strip at a time
        markupOn = on
        markupButton?.state = on ? .on : .off
        if on {
            let acc = NSTitlebarAccessoryViewController()
            acc.view = buildMarkupStrip(width: window.frame.width)
            acc.layoutAttribute = .bottom
            window.addTitlebarAccessoryViewController(acc)
            markupAccessory = acc
        } else {
            markupAccessory?.removeFromParent()
            markupAccessory = nil
            didSelect(nil)
        }
    }

    private func buildMarkupStrip(width: CGFloat) -> NSView {
        let strip = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        func b(_ title: String, _ action: Selector, _ x: CGFloat, _ w: CGFloat) -> NSButton {
            let btn = NSButton(title: title, target: self, action: action)
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            btn.frame = NSRect(x: x, y: 7, width: w, height: 26)
            strip.addSubview(btn)
            return btn
        }
        _ = b("Add Signature", #selector(addSignature), 12, 116)
        _ = b("Add Text", #selector(addText), 134, 84)
        _ = b("✓", #selector(addCheck), 224, 36)
        _ = b("✗", #selector(addCross), 264, 36)

        let sizeLabel = NSTextField(labelWithString: "Size")
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.frame = NSRect(x: 314, y: 12, width: 30, height: 16)
        strip.addSubview(sizeLabel)

        sizeSlider.frame = NSRect(x: 346, y: 9, width: 120, height: 22)
        sizeSlider.controlSize = .small
        sizeSlider.minValue = 14; sizeSlider.maxValue = 600
        sizeSlider.target = self; sizeSlider.action = #selector(resizeSelected)
        sizeSlider.isEnabled = false
        strip.addSubview(sizeSlider)

        removeButton.title = "Remove"
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.target = self; removeButton.action = #selector(removeSelected)
        removeButton.frame = NSRect(x: 478, y: 7, width: 76, height: 26)
        removeButton.isEnabled = false
        strip.addSubview(removeButton)

        if let doc = pdfView.document, hasFormFields(doc) {
            let hint = NSTextField(labelWithString: "Fillable form — click a field to type")
            hint.textColor = .secondaryLabelColor
            hint.font = .systemFont(ofSize: 11)
            hint.alignment = .right
            hint.frame = NSRect(x: width - 260, y: 12, width: 244, height: 16)
            hint.autoresizingMask = [.minXMargin]
            strip.addSubview(hint)
        }
        return strip
    }

    // MARK: - Redact mode (mark → apply destroys, then the output is adversarially verified)

    @objc func toggleRedact(_ sender: Any?) { setRedact(on: !redactOn) }

    private func setRedact(on: Bool) {
        guard redactOn != on, let window = window else { return }
        if on { setMarkup(on: false) }   // one tool strip at a time
        redactOn = on
        redactButton?.state = on ? .on : .off
        pdfView.redactMode = on
        if on {
            let acc = NSTitlebarAccessoryViewController()
            acc.view = buildRedactStrip(width: window.frame.width)
            acc.layoutAttribute = .bottom
            window.addTitlebarAccessoryViewController(acc)
            redactAccessory = acc
            updateRedactCount()
        } else {
            redactAccessory?.removeFromParent()
            redactAccessory = nil
        }
    }

    private func buildRedactStrip(width: CGFloat) -> NSView {
        let strip = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 40))

        let hint = NSTextField(labelWithString: "Drag over anything to mark it for redaction")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.frame = NSRect(x: 12, y: 12, width: 250, height: 16)
        strip.addSubview(hint)

        redactTermField.placeholderString = "Redact every occurrence of…"
        redactTermField.font = .systemFont(ofSize: 12)
        redactTermField.frame = NSRect(x: 268, y: 8, width: 200, height: 24)
        redactTermField.target = self
        redactTermField.action = #selector(redactAllMatches)
        strip.addSubview(redactTermField)

        let all = NSButton(title: "Mark All", target: self, action: #selector(redactAllMatches))
        all.bezelStyle = .rounded
        all.controlSize = .small
        all.frame = NSRect(x: 474, y: 7, width: 78, height: 26)
        strip.addSubview(all)

        redactCountLabel.textColor = .secondaryLabelColor
        redactCountLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        redactCountLabel.frame = NSRect(x: 560, y: 12, width: 90, height: 16)
        strip.addSubview(redactCountLabel)

        let clear = NSButton(title: "Clear Marks", target: self, action: #selector(clearRedactionMarks))
        clear.bezelStyle = .rounded
        clear.controlSize = .small
        clear.frame = NSRect(x: width - 268, y: 7, width: 100, height: 26)
        clear.autoresizingMask = [.minXMargin]
        strip.addSubview(clear)

        let apply = NSButton(title: "Apply Redactions…", target: self, action: #selector(applyRedactions))
        apply.bezelStyle = .rounded
        apply.controlSize = .small
        apply.keyEquivalent = "\r"
        apply.frame = NSRect(x: width - 160, y: 7, width: 148, height: 26)
        apply.autoresizingMask = [.minXMargin]
        strip.addSubview(apply)

        return strip
    }

    // From SigningPDFView after a rubber-band gesture: the mark exists — make it undoable.
    func redactionAdded(_ ann: RedactionAnnotation) {
        docUndo.registerUndo(withTarget: self) { $0.removeRedactionMark(ann) }
        docUndo.setActionName("Mark Redaction")
        updateRedactCount()
    }

    private func addRedactionMark(_ ann: RedactionAnnotation, to page: PDFPage) {
        page.addAnnotation(ann)
        docUndo.registerUndo(withTarget: self) { $0.removeRedactionMark(ann) }
        docUndo.setActionName("Mark Redaction")
        updateRedactCount()
        pdfView.needsDisplay = true
    }

    private func removeRedactionMark(_ ann: RedactionAnnotation) {
        guard let page = ann.page else { return }
        page.removeAnnotation(ann)
        docUndo.registerUndo(withTarget: self) { $0.addRedactionMark(ann, to: page) }
        docUndo.setActionName("Mark Redaction")
        updateRedactCount()
        forceRefresh()   // custom-annotation removal needs a forced repaint
    }

    private func allRedactionMarks() -> [(Int, RedactionAnnotation)] {
        guard let doc = pdfView.document else { return [] }
        var out: [(Int, RedactionAnnotation)] = []
        for i in 0..<doc.pageCount {
            for a in doc.page(at: i)?.annotations.compactMap({ $0 as? RedactionAnnotation }) ?? [] {
                out.append((i, a))
            }
        }
        return out
    }

    private func updateRedactCount() {
        let n = allRedactionMarks().count
        redactCountLabel.stringValue = n == 0 ? "" : "\(n) mark\(n == 1 ? "" : "s")"
    }

    @objc private func redactAllMatches() {
        let term = redactTermField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, let doc = pdfView.document else { return }
        let found = doc.findString(term, withOptions: [.caseInsensitive])
        guard !found.isEmpty else { infoAlert("No matches", "“\(term)” wasn’t found in the document."); return }
        for sel in found {
            for page in sel.pages {
                let r = sel.bounds(for: page).insetBy(dx: -2, dy: -2)
                guard r.width > 0, r.height > 0 else { continue }
                addRedactionMark(RedactionAnnotation(bounds: r), to: page)
            }
        }
        redactedTerms.insert(term)
        redactTermField.stringValue = ""
        pdfView.needsDisplay = true
    }

    @objc private func clearRedactionMarks() {
        let marks = allRedactionMarks()
        guard !marks.isEmpty, let doc = pdfView.document else { return }
        for (_, a) in marks { a.page?.removeAnnotation(a) }
        docUndo.registerUndo(withTarget: self) { me in
            for (i, a) in marks { (me.pdfView.document ?? doc).page(at: i)?.addAnnotation(a) }
            me.docUndo.registerUndo(withTarget: me) { $0.clearRedactionMarks() }
            me.updateRedactCount()
            me.pdfView.needsDisplay = true
        }
        docUndo.setActionName("Clear Redaction Marks")
        updateRedactCount()
        forceRefresh()
    }

    @objc private func applyRedactions() {
        guard let doc = pdfView.document, let window = window else { return }
        let marks = allRedactionMarks()
        guard !marks.isEmpty else {
            infoAlert("Nothing marked", "Drag over content (or use “Redact every occurrence of…”) to mark it first.")
            return
        }
        var redactions: [Int: [CGRect]] = [:]
        for (i, a) in marks { redactions[i, default: []].append(a.bounds) }
        let redactedPages = Array(redactions.keys).sorted()
        let terms = Array(redactedTerms)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = pdfURL.deletingPathExtension().lastPathComponent + "-redacted.pdf"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let out = panel.url, let self = self else { return }
            guard RedactionEngine.apply(doc, redactions: redactions, to: out) else {
                infoAlert("Redaction failed", "Couldn’t write the redacted PDF. Nothing was saved.")
                return
            }
            let issues = RedactionEngine.verify(outputURL: out, redactedPages: redactedPages, forbiddenTerms: terms)
            if issues.isEmpty {
                self.clearRedactionMarks()
                NSWorkspace.shared.activateFileViewerSelecting([out])
                NSSound(named: "Glass")?.play()
                let n = redactedPages.count
                infoAlert("Redaction verified",
                          "\(n) page\(n == 1 ? "" : "s") permanently flattened — 0 recoverable characters under the redactions, metadata removed. Saved as \(out.lastPathComponent).")
            } else {
                // Never leave a leaky artifact on disk.
                try? FileManager.default.removeItem(at: out)
                infoAlert("Redaction NOT verified — file deleted",
                          "The output failed verification and was deleted:\n\n• " + issues.joined(separator: "\n• "))
            }
        }
    }

    // MARK: - Clean for Sharing (flatten everything + strip metadata + optional lock)

    @objc func cleanForSharing(_ sender: Any?) {
        guard let doc = pdfView.document, let window = window else { return }

        let alert = NSAlert()
        alert.messageText = "Clean for Sharing"
        alert.informativeText = "Saves a copy with signatures and form entries flattened and all metadata (author, title, editing history) removed. Add a password to lock it too — or leave blank."
        let pw = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        pw.placeholderString = "Password (optional)"
        alert.accessoryView = pw
        alert.addButton(withTitle: "Clean…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let password = pw.stringValue

        let panel = NSSavePanel()
        panel.nameFieldStringValue = pdfURL.deletingPathExtension().lastPathComponent + "-clean.pdf"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let out = panel.url else { return }
            let ok: Bool
            if password.isEmpty {
                ok = RedactionEngine.apply(doc, redactions: [:], to: out)
            } else {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("jack-clean-\(UUID().uuidString).pdf")
                ok = RedactionEngine.apply(doc, redactions: [:], to: tmp)
                    && PDFDocument(url: tmp)?.write(to: out, withOptions: [
                        .userPasswordOption: password, .ownerPasswordOption: password]) == true
                try? FileManager.default.removeItem(at: tmp)
            }
            if ok {
                NSWorkspace.shared.activateFileViewerSelecting([out])
                NSSound(named: "Glass")?.play()
            } else {
                infoAlert("Clean failed", "Couldn’t write the cleaned PDF.")
            }
        }
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
        guard !text.isEmpty, let img = renderText(text, size: 48, pad: 12) else { return }
        place(img)
    }

    @objc private func addCheck() { if let img = renderText("✔", size: 72, pad: 6, weight: .bold) { place(img, defaultWidth: 24) } }
    @objc private func addCross() { if let img = renderText("✘", size: 72, pad: 6, weight: .bold) { place(img, defaultWidth: 24) } }

    private func renderText(_ text: String, size: CGFloat, pad: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.black
        ])
        let m = s.size()
        let imgSize = NSSize(width: ceil(m.width) + pad * 2, height: ceil(m.height) + pad * 2)
        let img = NSImage(size: imgSize)
        img.lockFocus()
        s.draw(at: NSPoint(x: pad, y: pad))
        img.unlockFocus()
        return img
    }

    private func place(_ image: NSImage, defaultWidth: CGFloat? = nil) {
        guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return }
        let box = page.bounds(for: .mediaBox)
        let width = defaultWidth ?? min(220, box.width * 0.4)
        let aspect = image.size.height <= 0 ? 1 : image.size.width / image.size.height
        let height = width / max(0.01, aspect)
        let origin = CGPoint(x: box.midX - width / 2, y: box.midY - height / 2)
        let ann = ImageStampAnnotation(image: image, bounds: CGRect(x: origin.x, y: origin.y, width: width, height: height))
        addStamp(ann, to: page)
        didSelect(ann)
    }

    // MARK: - Undoable stamp primitives (each registers its inverse, so redo comes free)

    private func addStamp(_ ann: ImageStampAnnotation, to page: PDFPage) {
        page.addAnnotation(ann)
        docUndo.registerUndo(withTarget: self) { $0.removeStampUndoable(ann) }
        docUndo.setActionName("Add Mark")
        markEdited()
        pdfView.needsDisplay = true
    }

    private func removeStampUndoable(_ ann: ImageStampAnnotation) {
        guard let page = ann.page ?? pageContaining(ann) else { return }
        page.removeAnnotation(ann)
        docUndo.registerUndo(withTarget: self) { me in
            me.addStamp(ann, to: page)
            me.didSelect(ann)
        }
        docUndo.setActionName("Remove Mark")
        markEdited()
        if selected === ann { selected = nil }
        forceRefresh()   // PDFView caches page renders; deletes need a forced repaint
        didSelect(lastStamp())
    }

    private func pageContaining(_ ann: ImageStampAnnotation) -> PDFPage? {
        guard let doc = pdfView.document else { return nil }
        for i in 0..<doc.pageCount where doc.page(at: i)?.annotations.contains(ann) == true {
            return doc.page(at: i)
        }
        return nil
    }

    // One drag or one slider gesture = one undo step, restoring the pre-gesture bounds.
    private func registerBoundsUndo(_ ann: ImageStampAnnotation, _ oldBounds: CGRect, name: String) {
        docUndo.registerUndo(withTarget: self) { me in
            let current = ann.bounds
            ann.bounds = oldBounds
            me.registerBoundsUndo(ann, current, name: name)
            if me.selected === ann { me.sizeSlider.doubleValue = Double(oldBounds.width) }
            me.pdfView.needsDisplay = true
        }
        docUndo.setActionName(name)
        markEdited()
    }

    func stampMoved(_ ann: ImageStampAnnotation, from oldBounds: CGRect) {
        registerBoundsUndo(ann, oldBounds, name: "Move Mark")
    }

    private func hasFormFields(_ doc: PDFDocument) -> Bool {
        for i in 0..<doc.pageCount {
            if let p = doc.page(at: i), p.annotations.contains(where: { $0.type == "Widget" }) { return true }
        }
        return false
    }

    // Called by SigningPDFView when a stamp is clicked.
    func didSelect(_ ann: ImageStampAnnotation?) {
        if selected !== ann { selected?.outline = false }
        selected = ann
        ann?.outline = true
        if let ann = ann {
            sizeSlider.doubleValue = Double(ann.bounds.width)
            if !markupOn { setMarkup(on: true) }   // clicking a stamp surfaces its controls
        }
        sizeSlider.isEnabled = ann != nil
        removeButton.isEnabled = ann != nil
        pdfView.needsDisplay = true
    }

    private func lastStamp() -> ImageStampAnnotation? {
        guard let doc = pdfView.document else { return nil }
        for i in stride(from: doc.pageCount - 1, through: 0, by: -1) {
            if let s = doc.page(at: i)?.annotations.compactMap({ $0 as? ImageStampAnnotation }).last { return s }
        }
        return nil
    }

    @objc private func resizeSelected() {
        guard let ann = selected ?? lastStamp() else { return }
        if sliderStartBounds == nil { sliderStartBounds = ann.bounds }
        let newW = CGFloat(sizeSlider.doubleValue)
        let newH = newW / max(0.01, ann.aspect)
        let cx = ann.bounds.midX, cy = ann.bounds.midY
        ann.bounds = CGRect(x: cx - newW / 2, y: cy - newH / 2, width: newW, height: newH)
        pdfView.needsDisplay = true
        if NSApp.currentEvent?.type == .leftMouseUp {   // gesture ended
            if let start = sliderStartBounds, start != ann.bounds {
                registerBoundsUndo(ann, start, name: "Resize Mark")
            }
            sliderStartBounds = nil
        }
    }

    @objc private func removeSelected() {
        guard let ann = selected ?? lastStamp() else { return }
        removeStampUndoable(ann)
    }

    // MARK: - Sidebar (organizer) delegate

    func sidebarDidSelectPage(_ index: Int) {
        guard let page = pdfView.document?.page(at: index) else { return }
        pdfView.go(to: page)
    }

    func sidebarDidModifyDocument() {
        markEdited()
        forceRefresh()
    }

    func sidebarRequestsExtract(_ indexes: [Int]) {
        guard let doc = pdfView.document, let window = window else { return }
        let out = PDFDocument()
        var n = 0
        for i in indexes {
            if let p = doc.page(at: i), let copy = p.copy() as? PDFPage { out.insert(copy, at: n); n += 1 }
        }
        guard n > 0 else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = pdfURL.deletingPathExtension().lastPathComponent + "-pages.pdf"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            if out.write(to: url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                NSSound(named: "Glass")?.play()
            } else {
                infoAlert("Save failed", "Couldn’t write the extracted PDF.")
            }
        }
    }

    private func markEdited() { window?.isDocumentEdited = true }

    private func forceRefresh() {
        let page = pdfView.currentPage
        let doc = pdfView.document
        pdfView.document = nil
        pdfView.document = doc
        if let page = page, page.document != nil { pdfView.go(to: page) }
        pageChanged()
    }

    // MARK: - Save (flatten stamps + form values, keep the original file untouched)

    @objc func saveDocument(_ sender: Any?) {
        guard let doc = pdfView.document, let window = window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = pdfURL.deletingPathExtension().lastPathComponent + "-edited.pdf"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let out = panel.url, let self = self else { return }
            if self.flatten(doc, to: out) {
                self.window?.isDocumentEdited = false
                NSWorkspace.shared.activateFileViewerSelecting([out])
                NSSound(named: "Glass")?.play()
            } else {
                infoAlert("Save failed", "Couldn’t write the PDF.")
            }
        }
    }

    // Burn stamps (and rendered form-field values) into page content so the result is portable.
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

    // MARK: - Lock for Sharing

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
        guard !password.isEmpty else { infoAlert("No password", "Enter a password to lock the PDF."); return }
        guard password == verify.stringValue else { infoAlert("Passwords don’t match", "The two password fields must match."); return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = pdfURL.deletingPathExtension().lastPathComponent + "-locked.pdf"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let out = panel.url else { return }
            let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
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
        if searchField?.stringValue.isEmpty == true { clearSearch() }
    }

    @objc private func searchChanged() {
        guard let term = searchField?.stringValue, !term.isEmpty else { clearSearch(); return }
        guard let doc = pdfView.document else { return }
        matches = doc.findString(term, withOptions: [.caseInsensitive])
        matchIndex = 0
        for m in matches { m.color = NSColor.systemYellow.withAlphaComponent(0.6) }
        pdfView.highlightedSelections = matches.isEmpty ? nil : matches
        matches.isEmpty ? setSubtitle("No matches") : showMatch()
    }

    private func clearSearch() {
        matches = []
        matchIndex = 0
        pdfView.highlightedSelections = nil
        pdfView.setCurrentSelection(nil, animate: false)
        pageChanged()
    }

    private func showMatch() {
        guard !matches.isEmpty else { return }
        let sel = matches[matchIndex]
        setSubtitle("Match \(matchIndex + 1) of \(matches.count)")
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
