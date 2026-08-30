// The document window: one window per PDF, Preview-style. Native unified toolbar (sidebar,
// zoom, Markup, Lock, Print, search, Save), a Markup tool strip that slides in beneath the
// title bar, and a sidebar that is the page organizer. No secondary windows, no "Home".
import AppKit
import PDFKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                      StampSelectionDelegate, PageSidebarDelegate, NSSearchFieldDelegate,
                                      NSMenuDelegate {

    // v2.0: the file's identity lives with the NSDocument (rename/move/duplicate are native).
    private var exportBaseName: String {
        (document as? NSDocument)?.fileURL == nil ? "Untitled"
            : pdfURL.deletingPathExtension().lastPathComponent
    }
    private var pdfURL: URL {
        (document as? NSDocument)?.fileURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
    private let pdfView = SigningPDFView()
    private var uiBuilt = false

    // Custom title control (v1.8 look Keno approved): title + ⌄ + subtitle as one unit.
    private var titleChevron: NSButton?
    private var renamePopover: NSPopover?
    private let titleButton = NSButton(title: "", target: nil, action: nil)
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var titleContainer: NSView?
    private weak var renameField: NSTextField?
    private weak var renameWherePopup: NSPopUpButton?
    private var pendingRenameName: String?
    private var pendingRenameWhere: URL?

    // Restoration builds this controller before the document's read completes.
    func attachDocumentIfNeeded() {
        guard !uiBuilt, let doc = (document as? JackDocument)?.pdf else { return }
        uiBuilt = true
        buildUI(doc: doc)
        presentWindow()
    }

    // NSDocument's display:true does not reliably order our hand-built window onscreen
    // (window-server showed it existing with onscreen=false) — show it ourselves, always.
    func presentWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let sidebar = PageSidebarController()
    private var searchField: NSSearchField?
    private weak var saveButton: NSButton?
    private var subtitleBase = ""
    private weak var selected: ImageStampAnnotation?
    private var sheet: SignatureSheetController?

    // Undo lives with the document — registrations drive the dirty state and autosave.
    private var docUndo: UndoManager { (document as? NSDocument)?.undoManager ?? UndoManager() }
    private var sliderStartBounds: CGRect?   // resize gesture start, so one drag = one undo step

    private var matches: [PDFSelection] = []
    private var matchIndex = 0
    // Clicking toolbar/menu chrome can clear the live selection before the action runs
    // (Tahoe focus behavior) — annotate actions fall back to the last real selection.
    private var lastSelection: PDFSelection?
    private var sidebarVisible = true
    private var markupOn = false
    private let sidebarWidth: CGFloat = 172

    // Ask panel (on-device model; only exists when Apple Intelligence is available)
    private var askVisible = false
    private let askWidth: CGFloat = 320
    private let askPanel = NSView()
    private let askQuestion = NSTextField()
    private let askAnswer = NSTextView()
    private let askSpinner = NSProgressIndicator()
    private var askButton: NSButton?
    private var askRunning = false

    // Markup strip controls
    private var markupAccessory: NSTitlebarAccessoryViewController?
    private let sizeSlider = NSSlider()
    private let removeButton = NSButton()
    private var markupButton: NSButton?
    private var shareButton: NSButton?

    // Redact strip controls
    private var redactOn = false
    private var redactAccessory: NSTitlebarAccessoryViewController?
    private var redactButton: NSButton?
    private let redactCountLabel = NSTextField(labelWithString: "")
    private let redactTermField = NSTextField()
    private var redactedTerms: Set<String> = []   // fed to the verify pass as forbidden terms

    // Redactions applied in this session. The save path reads this to emit the verification
    // certificate beside the file the user actually wrote.
    private(set) var redactedPageLog: Set<Int> = []
    private(set) var redactedRegionCount = 0
    var pendingCertificateInfo: (pages: [Int], regions: Int, terms: [String])? {
        redactedPageLog.isEmpty ? nil : (redactedPageLog.sorted(), redactedRegionCount, Array(redactedTerms))
    }
    func noteCertificate(_ message: String) { flashSubtitle(message) }

    // Erase strip controls (whiteout that actually removes)
    private var eraseOn = false
    private var eraseAccessory: NSTitlebarAccessoryViewController?
    private var eraseButton: NSButton?
    private let eraseCountLabel = NSTextField(labelWithString: "")

    // Form strip controls (field authoring)
    private var formOn = false
    private var formAccessory: NSTitlebarAccessoryViewController?
    private var formButton: NSButton?
    private var formPaletteButtons: [NSButton] = []
    private var fieldPopover: NSPopover?
    private weak var fieldNameField: NSTextField?
    private weak var fieldOptionsView: NSTextView?
    private var editingFieldName: String?
    private var lastImageHit: (image: PDFPageImage, page: PDFPage)?

    init(document: JackDocument) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.center()
        win.setFrameAutosaveName("JackDocument")
        super.init(window: win)
        self.document = document
        shouldCloseDocument = true
        win.delegate = self
        if let doc = document.pdf { buildUI(doc: doc); uiBuilt = true }
        AppDelegate.documents.append(self)
        AppDelegate.updateActivationPolicy()
        if uiBuilt { DispatchQueue.main.async { [weak self] in self?.presentWindow() } }
    }

    required init?(coder: NSCoder) { fatalError() }

    func openInMarkup() {
        DispatchQueue.main.async { [weak self] in self?.setMarkup(on: true) }
    }

    // ⌘Z / Edit menu / toolbar Undo all resolve here through the window.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        (document as? NSDocument)?.undoManager
    }

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
        installTitleChevron(on: window)

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
        if AskEngine.isAvailable { buildAskPanel() }
        content.addSubview(askPanel)
        layoutViews()

        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                               name: .PDFViewSelectionChanged, object: pdfView)
        pdfView.annotateMenuItems = { [weak self] page, point in
            guard let self else { return [] }
            var items = self.buildAnnotateMenuItems(page: page, point: point)
            // Right-clicked on a picture? Offer it like a browser would.
            if let page, let hit = ImageHitEngine.image(at: point, on: page) {
                self.lastImageHit = (hit, page)
                let copy = NSMenuItem(title: "Copy Image", action: #selector(self.copyHitImage(_:)), keyEquivalent: "")
                copy.target = self
                let save = NSMenuItem(title: "Save Image As…", action: #selector(self.saveHitImage(_:)), keyEquivalent: "")
                save.target = self
                items.insert(.separator(), at: 0)
                items.insert(save, at: 0)
                items.insert(copy, at: 0)
                if ObjectRemovalEngine.canRemove(hit) {
                    let remove = NSMenuItem(title: "Remove Object",
                                            action: #selector(self.removeHitObject(_:)), keyEquivalent: "")
                    remove.target = self
                    items.insert(remove, at: 2)
                }
            }
            return items
        }
        // A locked doc builds blank thumbnails; re-render everything once the password lands.
        NotificationCenter.default.addObserver(self, selector: #selector(documentUnlocked),
                                               name: .PDFDocumentDidUnlock, object: doc)
        // Typing into AcroForm fields bypasses our undo path — count it so autosave captures it.
        NotificationCenter.default.addObserver(self, selector: #selector(annotationHit(_:)),
                                               name: .PDFViewAnnotationHit, object: pdfView)
        // v2.5: nothing is written until the user saves, so the Save button and the subtitle
        // are the only signals that work is pending — keep them honest.
        NotificationCenter.default.addObserver(self, selector: #selector(dirtyChanged),
                                               name: .jackDocumentDirtyChanged, object: document)
        sidebar.reload()
        pageChanged()
    }

    private func layoutViews() {
        guard let content = window?.contentView else { return }
        let sw = sidebarVisible ? sidebarWidth : 0
        let aw = askVisible ? askWidth : 0
        sidebar.scrollView.frame = NSRect(x: 0, y: 0, width: sw, height: content.bounds.height)
        sidebar.scrollView.isHidden = !sidebarVisible
        sidebar.scrollView.autoresizingMask = [.height]
        pdfView.frame = NSRect(x: sw, y: 0, width: content.bounds.width - sw - aw, height: content.bounds.height)
        pdfView.autoresizingMask = [.width, .height]
        askPanel.frame = NSRect(x: content.bounds.width - aw, y: 0, width: askWidth, height: content.bounds.height)
        askPanel.isHidden = !askVisible
        askPanel.autoresizingMask = [.height, .minXMargin]
    }

    @objc private func selectionChanged() {
        if let s = pdfView.currentSelection,
           !(s.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastSelection = s
        }
    }

    @objc private func documentUnlocked() {
        sidebar.reload()
        forceRefresh()
    }

    @objc private func annotationHit(_ note: Notification) {
        if let ann = note.userInfo?["PDFAnnotationHit"] as? PDFAnnotation, ann.type == "Widget" {
            (document as? NSDocument)?.updateChangeCount(.changeDone)
        }
    }

    @objc private func pageChanged() {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return }
        let index = doc.index(for: page)
        setSubtitle("Page \(index + 1) of \(doc.pageCount)")
        sidebar.highlight(pageIndex: index)
    }

    private func setSubtitle(_ s: String) {
        subtitleBase = s
        let doc = document as? JackDocument
        let dirty = doc?.isDocumentEdited == true
        // While edits are pending on someone else's PDF, say plainly that their file is safe.
        let suffix: String
        if dirty {
            suffix = doc?.protectsOriginal == true ? " — Edited · original unchanged" : " — Edited"
        } else {
            suffix = ""
        }
        subtitleLabel.stringValue = s + suffix
    }

    @objc private func dirtyChanged() {
        setSubtitle(subtitleBase)
        saveButton?.isEnabled = (document as? NSDocument)?.isDocumentEdited == true
    }

    // NSDocument re-syncs the title on rename/move/duplicate — keep our control in step.
    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        DispatchQueue.main.async { [weak self] in self?.layoutTitleAccessory() }
        return displayName
    }

    // MARK: - Toolbar

    private enum ItemID {
        static let undo = NSToolbarItem.Identifier("jack.undo")
        static let redo = NSToolbarItem.Identifier("jack.redo")
        static let sidebar = NSToolbarItem.Identifier("jack.sidebar")
        static let zoomOut = NSToolbarItem.Identifier("jack.zoomOut")
        static let zoomIn = NSToolbarItem.Identifier("jack.zoomIn")
        static let markup = NSToolbarItem.Identifier("jack.markup")
        static let form = NSToolbarItem.Identifier("jack.form")
        static let erase = NSToolbarItem.Identifier("jack.erase")
        static let redact = NSToolbarItem.Identifier("jack.redact")
        static let clean = NSToolbarItem.Identifier("jack.clean")
        static let tools = NSToolbarItem.Identifier("jack.tools")
        static let share = NSToolbarItem.Identifier("jack.share")
        static let ask = NSToolbarItem.Identifier("jack.ask")
        static let highlight = NSToolbarItem.Identifier("jack.highlight")
        static let lock = NSToolbarItem.Identifier("jack.lock")
        static let print = NSToolbarItem.Identifier("jack.print")
        static let save = NSToolbarItem.Identifier("jack.save")       // Export a flattened copy
        static let saveDoc = NSToolbarItem.Identifier("jack.saveDoc") // Save the document itself
        static let search = NSToolbarItem.Identifier("jack.search")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var ids: [NSToolbarItem.Identifier] =
        [ItemID.sidebar, .space, ItemID.undo, ItemID.redo, .flexibleSpace, ItemID.zoomOut, ItemID.zoomIn, .space,
         ItemID.highlight, ItemID.markup, ItemID.form, ItemID.erase, ItemID.redact, ItemID.clean, ItemID.lock, ItemID.tools, ItemID.print, ItemID.share, .flexibleSpace, ItemID.search, ItemID.saveDoc, ItemID.save]
        if AskEngine.isAvailable, let i = ids.firstIndex(of: ItemID.share) {
            ids.insert(ItemID.ask, at: i + 1)
        }
        return ids
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
        case ItemID.sidebar:
            // Preview-style view pull-down: Thumbnails toggle + page display modes.
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "View")
            item.label = "View"
            item.toolTip = "Thumbnails and page layout"
            let menu = NSMenu()
            menu.delegate = self
            menu.addItem({ let m = NSMenuItem(title: "Thumbnails", action: #selector(toggleSidebar(_:)), keyEquivalent: ""); m.target = self; m.tag = 100; return m }())
            menu.addItem(.separator())
            menu.addItem({ let m = NSMenuItem(title: "Continuous Scroll", action: #selector(displayContinuous(_:)), keyEquivalent: ""); m.target = self; m.tag = 101; return m }())
            menu.addItem({ let m = NSMenuItem(title: "Single Page", action: #selector(displaySinglePage(_:)), keyEquivalent: ""); m.target = self; m.tag = 102; return m }())
            menu.addItem({ let m = NSMenuItem(title: "Two Pages", action: #selector(displayTwoPages(_:)), keyEquivalent: ""); m.target = self; m.tag = 103; return m }())
            item.menu = menu
            return item
        case ItemID.ask:
            let item = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(image: NSImage(systemSymbolName: "wand.and.stars",
                                            accessibilityDescription: "Ask") ?? NSImage(),
                             target: self, action: #selector(toggleAsk(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .texturedRounded
            askButton = b
            item.view = b
            item.label = "Ask"
            item.toolTip = "Ask this PDF — answers on this Mac, nothing uploaded"
            return item
        case ItemID.share:
            let item = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up",
                                            accessibilityDescription: "Share") ?? NSImage(),
                             target: self, action: #selector(shareDocument(_:)))
            b.bezelStyle = .texturedRounded
            shareButton = b
            item.view = b
            item.label = "Share"
            item.toolTip = "Share — AirDrop, Mail, Messages…"
            return item
        case ItemID.undo:    return simple(id, "arrow.uturn.backward", "Undo", #selector(undoEdit(_:)))
        case ItemID.redo:    return simple(id, "arrow.uturn.forward", "Redo", #selector(redoEdit(_:)))
        case ItemID.zoomOut: return simple(id, "minus.magnifyingglass", "Zoom Out", #selector(zoomOut(_:)))
        case ItemID.zoomIn:  return simple(id, "plus.magnifyingglass", "Zoom In", #selector(zoomIn(_:)))
        case ItemID.lock:    return simple(id, "lock", "Lock for Sharing", #selector(lockForSharing(_:)))
        case ItemID.clean:   return simple(id, "sparkles", "Clean for Sharing", #selector(cleanForSharing(_:)))
        case ItemID.tools:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Tools")
            item.label = "Tools"
            item.toolTip = "Document tools"
            let menu = NSMenu()
            menu.addItem({ let m = NSMenuItem(title: "Make Searchable (OCR)…", action: #selector(makeSearchable(_:)), keyEquivalent: ""); m.target = self; return m }())
            menu.addItem({ let m = NSMenuItem(title: "Bates Numbering…", action: #selector(batesNumbering(_:)), keyEquivalent: ""); m.target = self; return m }())
            menu.addItem({ let m = NSMenuItem(title: "Watermark…", action: #selector(addWatermark(_:)), keyEquivalent: ""); m.target = self; return m }())
            menu.addItem({ let m = NSMenuItem(title: "Compress…", action: #selector(compressDocument(_:)), keyEquivalent: ""); m.target = self; return m }())
            menu.addItem(.separator())
            menu.addItem({ let m = NSMenuItem(title: "Copy Region as Image", action: #selector(copyRegionAsImage(_:)), keyEquivalent: ""); m.target = self; return m }())
            menu.addItem({ let m = NSMenuItem(title: "Save Region as Image…", action: #selector(saveRegionAsImage(_:)), keyEquivalent: ""); m.target = self; return m }())
            menu.addItem(.separator())
            menu.addItem({ let m = NSMenuItem(title: "Crop Pages…", action: #selector(cropPages(_:)), keyEquivalent: ""); m.target = self; return m }())
            menu.addItem({ let m = NSMenuItem(title: "Remove Crop", action: #selector(removeCrop(_:)), keyEquivalent: ""); m.target = self; return m }())
            item.menu = menu
            return item
        case ItemID.highlight:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: "Annotate")
            item.label = "Annotate"
            item.toolTip = "Highlight, underline, strikethrough"
            let menu = NSMenu()
            for (i, entry) in Self.highlightColors.enumerated() {
                let m = NSMenuItem(title: "Highlight \(entry.name)", action: #selector(highlightColorPicked(_:)), keyEquivalent: "")
                m.target = self
                m.tag = i
                m.image = Self.swatch(entry.color)
                menu.addItem(m)
            }
            menu.addItem(.separator())
            menu.addItem({ let m = NSMenuItem(title: "Underline", action: #selector(underlineSelection(_:)), keyEquivalent: ""); m.target = self; m.image = Self.swatch(.systemBlue); return m }())
            menu.addItem({ let m = NSMenuItem(title: "Strikethrough", action: #selector(strikethroughSelection(_:)), keyEquivalent: ""); m.target = self; m.image = Self.swatch(.systemRed); return m }())
            menu.addItem(.separator())
            menu.addItem({ let m = NSMenuItem(title: "Add Comment…", action: #selector(addComment(_:)), keyEquivalent: ""); m.target = self; m.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil); return m }())
            item.menu = menu
            return item
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
        case ItemID.erase:
            let item = NSToolbarItem(itemIdentifier: id)
            let img = NSImage(systemSymbolName: "eraser", accessibilityDescription: "Erase")
                ?? NSImage(systemSymbolName: "rectangle.badge.minus", accessibilityDescription: "Erase")
            let b = NSButton(image: img ?? NSImage(), target: self, action: #selector(toggleErase(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .texturedRounded
            eraseButton = b
            item.view = b
            item.label = "Erase"
            item.toolTip = "Erase — remove logos, addresses, anything (verified removal, reads as blank paper)"
            return item
        case ItemID.form:
            let item = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(image: NSImage(systemSymbolName: "character.textbox",
                                            accessibilityDescription: "Form") ?? NSImage(),
                             target: self, action: #selector(toggleForm(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .texturedRounded
            formButton = b
            item.view = b
            item.label = "Form"
            item.toolTip = "Prepare Form — add fillable fields"
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
        case ItemID.saveDoc:
            // v2.5: the document is only written when this is used. It lights up when there
            // is something to write, and is the one control that touches the user's file.
            let item = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(title: "Save", target: self, action: #selector(saveDocumentAction(_:)))
            b.bezelStyle = .texturedRounded
            b.keyEquivalent = ""
            b.isEnabled = (document as? NSDocument)?.isDocumentEdited == true
            saveButton = b
            item.view = b
            item.label = "Save"
            item.toolTip = "Save your changes (⌘S) — the first save of someone else's PDF makes a copy"
            return item
        case ItemID.save:
            let item = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(title: "Export…", target: self, action: #selector(exportFlattened(_:)))
            b.bezelStyle = .texturedRounded
            item.view = b
            item.label = "Export"
            item.toolTip = "Export a flattened copy — annotations and signatures burned in"
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

    // Routed through NSDocument so the toolbar button and ⌘S share one code path
    // (including the first-save-makes-a-copy rule in JackDocument.saveDocument).
    @objc func saveDocumentAction(_ sender: Any?) { (document as? NSDocument)?.save(sender) }

    @objc func toggleSidebar(_ sender: Any?) { sidebarVisible.toggle(); layoutViews() }
    @objc func undoEdit(_ sender: Any?) { docUndo.undo() }
    @objc func redoEdit(_ sender: Any?) { docUndo.redo() }
    @objc func displayContinuous(_ sender: Any?) { pdfView.displayMode = .singlePageContinuous; pdfView.autoScales = true }
    @objc func displaySinglePage(_ sender: Any?) { pdfView.displayMode = .singlePage; pdfView.autoScales = true }
    @objc func displayTwoPages(_ sender: Any?) { pdfView.displayMode = .twoUpContinuous; pdfView.autoScales = true }

    // Keep the View pull-down's checkmarks true to the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.tag {
            case 100: item.state = sidebarVisible ? .on : .off
            case 101: item.state = pdfView.displayMode == .singlePageContinuous ? .on : .off
            case 102: item.state = pdfView.displayMode == .singlePage ? .on : .off
            case 103: item.state = pdfView.displayMode == .twoUpContinuous ? .on : .off
            default: break
            }
        }
    }

    // MARK: - Share (native picker: AirDrop, Mail, Messages…) — shares the state on screen

    @objc func shareDocument(_ sender: Any?) {
        guard let anchor = shareButton else { return }
        var url = pdfURL
        if (document as? NSDocument)?.isDocumentEdited == true, let doc = pdfView.document {
            // Share what the user sees — the same representation a save would write.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("jack-share-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent(pdfURL.lastPathComponent)
            if let data = JackDocument.buildPersistedDocument(from: doc)?.dataRepresentation(),
               (try? data.write(to: tmp)) != nil {
                url = tmp
            }
        }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    // MARK: - Ask panel (on-device model)

    @objc func toggleAsk(_ sender: Any?) {
        askVisible.toggle()
        askButton?.state = askVisible ? .on : .off
        layoutViews()
        if askVisible { window?.makeFirstResponder(askQuestion) }
    }

    private func buildAskPanel() {
        let w = askWidth
        let h: CGFloat = 700
        // The container MUST have this frame before children are added — autoresizing
        // springs are computed against it (zero-frame parent flings everything off-view).
        askPanel.frame = NSRect(x: 0, y: 0, width: w, height: h)
        askPanel.wantsLayer = true
        askPanel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let divider = NSBox(frame: NSRect(x: 0, y: 0, width: 1, height: h))
        divider.boxType = .separator
        divider.autoresizingMask = [.height]
        askPanel.addSubview(divider)

        let title = NSTextField(labelWithString: "Ask this PDF")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: 16, y: h - 34, width: w - 60, height: 20)
        title.autoresizingMask = [.minYMargin]
        askPanel.addSubview(title)

        askSpinner.style = .spinning
        askSpinner.controlSize = .small
        askSpinner.isDisplayedWhenStopped = false
        askSpinner.frame = NSRect(x: w - 36, y: h - 34, width: 18, height: 18)
        askSpinner.autoresizingMask = [.minYMargin]
        askPanel.addSubview(askSpinner)

        let privacy = NSTextField(labelWithString: "Answers on this Mac — nothing is uploaded.")
        privacy.font = .systemFont(ofSize: 10)
        privacy.textColor = .secondaryLabelColor
        privacy.frame = NSRect(x: 16, y: h - 52, width: w - 32, height: 14)
        privacy.autoresizingMask = [.minYMargin]
        askPanel.addSubview(privacy)

        func quick(_ label: String, _ q: String, x: CGFloat, width: CGFloat) -> NSButton {
            let b = NSButton(title: label, target: self, action: #selector(quickAsk(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.frame = NSRect(x: x, y: h - 84, width: width, height: 24)
            b.autoresizingMask = [.minYMargin]
            b.toolTip = q
            b.identifier = NSUserInterfaceItemIdentifier(q)
            askPanel.addSubview(b)
            return b
        }
        _ = quick("Summarize", "__summarize__", x: 16, width: 92)
        _ = quick("Key dates", "List every date and deadline mentioned in the document.", x: 112, width: 92)
        _ = quick("Amounts", "List every dollar amount mentioned and what it is for.", x: 208, width: 92)

        askQuestion.placeholderString = "Ask a question about this document…"
        askQuestion.font = .systemFont(ofSize: 12)
        askQuestion.frame = NSRect(x: 16, y: h - 118, width: w - 88, height: 24)
        askQuestion.autoresizingMask = [.minYMargin]
        askQuestion.target = self
        askQuestion.action = #selector(askSubmitted(_:))
        askPanel.addSubview(askQuestion)

        let go = NSButton(title: "Ask", target: self, action: #selector(askSubmitted(_:)))
        go.bezelStyle = .rounded
        go.frame = NSRect(x: w - 66, y: h - 121, width: 50, height: 28)
        go.autoresizingMask = [.minYMargin]
        askPanel.addSubview(go)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 14, width: w - 32, height: h - 146))
        scroll.autoresizingMask = [.height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        askAnswer.frame = scroll.bounds
        askAnswer.isEditable = false
        askAnswer.font = .systemFont(ofSize: 12.5)
        askAnswer.drawsBackground = false
        askAnswer.textContainerInset = NSSize(width: 0, height: 4)
        askAnswer.autoresizingMask = [.width]
        scroll.documentView = askAnswer
        askPanel.addSubview(scroll)
    }

    @objc private func quickAsk(_ sender: NSButton) {
        runAsk(sender.identifier?.rawValue ?? "")
    }

    @objc private func askSubmitted(_ sender: Any?) {
        let q = askQuestion.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        runAsk(q)
    }

    private func runAsk(_ question: String) {
        guard !askRunning, let doc = pdfView.document else { return }
        askRunning = true
        askSpinner.startAnimation(nil)
        askAnswer.string = question == "__summarize__" ? "Summarizing…" : "Thinking…"
        Task { [weak self] in
            var result: String
            do {
                if question == "__summarize__" {
                    result = try await AskEngine.summarize(doc: doc) { done, total in
                        DispatchQueue.main.async { self?.askAnswer.string = "Reading page group \(done) of \(total)…" }
                    }
                } else {
                    result = try await AskEngine.answer(question: question, doc: doc)
                }
            } catch {
                result = "Couldn’t get an answer: \(error.localizedDescription)"
            }
            await MainActor.run {
                self?.askAnswer.string = result
                self?.askSpinner.stopAnimation(nil)
                self?.askRunning = false
            }
        }
    }

    // MARK: - Title control + rename popover (v1.8 UX on the NSDocument backbone)

    private func installTitleChevron(on window: NSWindow) {
        window.titleVisibility = .hidden

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 34))

        titleButton.isBordered = false
        titleButton.alignment = .left
        titleButton.lineBreakMode = .byTruncatingMiddle
        titleButton.target = self
        titleButton.action = #selector(renameDocument(_:))
        titleButton.toolTip = "Rename…"
        container.addSubview(titleButton)

        let b = NSButton(frame: .zero)
        b.isBordered = false
        b.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Rename")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        b.contentTintColor = .tertiaryLabelColor
        b.target = self
        b.action = #selector(renameDocument(_:))
        b.toolTip = "Rename…"
        container.addSubview(b)
        titleChevron = b

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(subtitleLabel)

        titleContainer = container
        let acc = NSTitlebarAccessoryViewController()
        acc.view = container
        acc.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(acc)
        layoutTitleAccessory()
    }

    private func layoutTitleAccessory() {
        guard let container = titleContainer else { return }
        // An untitled document has no fileURL — show NSDocument's name ("Untitled"),
        // never the fallback directory's name.
        let name = (document as? NSDocument)?.fileURL == nil
            ? ((document as? NSDocument)?.displayName ?? "Untitled")
            : pdfURL.lastPathComponent
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleButton.attributedTitle = NSAttributedString(string: name, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor
        ])
        let titleWidth = min(ceil(name.size(withAttributes: [.font: font]).width) + 8, 420)
        titleButton.frame = NSRect(x: 4, y: 15, width: titleWidth, height: 18)
        titleChevron?.frame = NSRect(x: titleButton.frame.maxX, y: 16, width: 16, height: 16)
        subtitleLabel.frame = NSRect(x: 6, y: 0, width: max(titleWidth + 40, 200), height: 14)
        container.frame = NSRect(x: 0, y: 0,
                                 width: max(titleButton.frame.maxX + 20, subtitleLabel.frame.maxX),
                                 height: 34)
    }

    @objc func renameDocument(_ sender: Any?) {
        renamePopover?.close()
        // Untitled: there is nothing on disk to rename — the native save panel names it.
        if (document as? NSDocument)?.fileURL == nil {
            (document as? NSDocument)?.save(withDelegate: nil, didSave: nil, contextInfo: nil)
            return
        }
        let vc = NSViewController()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 96))

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.alignment = .right
        nameLabel.frame = NSRect(x: 10, y: 58, width: 56, height: 18)
        v.addSubview(nameLabel)
        let field = NSTextField(frame: NSRect(x: 74, y: 54, width: 252, height: 24))
        field.stringValue = pdfURL.deletingPathExtension().lastPathComponent
        field.target = self
        field.action = #selector(commitRename(_:))
        v.addSubview(field)

        let whereLabel = NSTextField(labelWithString: "Where:")
        whereLabel.alignment = .right
        whereLabel.textColor = .secondaryLabelColor
        whereLabel.frame = NSRect(x: 10, y: 31, width: 56, height: 16)
        v.addSubview(whereLabel)

        // Live folder picker: choosing a different folder MOVES the file (via NSDocument).
        let popup = NSPopUpButton(frame: NSRect(x: 72, y: 26, width: 256, height: 26), pullsDown: false)
        let fm = FileManager.default
        let current = pendingRenameWhere ?? pdfURL.deletingLastPathComponent()
        func folderItem(_ url: URL) -> NSMenuItem {
            let m = NSMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            m.image = icon
            m.representedObject = url
            return m
        }
        let menu = NSMenu()
        menu.addItem(folderItem(current))
        var commons: [URL] = []
        for dir: FileManager.SearchPathDirectory in [.desktopDirectory, .documentDirectory, .downloadsDirectory] {
            if let u = fm.urls(for: dir, in: .userDomainMask).first,
               u.standardizedFileURL != current.standardizedFileURL { commons.append(u) }
        }
        if !commons.isEmpty {
            menu.addItem(.separator())
            commons.forEach { menu.addItem(folderItem($0)) }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Other…", action: nil, keyEquivalent: ""))
        popup.menu = menu
        popup.selectItem(at: 0)
        popup.target = self
        popup.action = #selector(wherePopupChanged(_:))
        v.addSubview(popup)
        renameWherePopup = popup
        if let pending = pendingRenameName { field.stringValue = pending }
        pendingRenameName = nil

        let button = NSButton(title: "Rename", target: self, action: #selector(commitRename(_:)))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.frame = NSRect(x: 246, y: 4, width: 84, height: 26)
        v.addSubview(button)

        vc.view = v
        renameField = field
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        if let chevron = titleChevron {
            pop.show(relativeTo: chevron.bounds, of: chevron, preferredEdge: .maxY)
        }
        renamePopover = pop
        pop.contentViewController?.view.window?.makeFirstResponder(field)
    }

    // "Other…" needs an open panel, which dismisses the transient popover — stash the typed
    // name, run the panel, then reopen the popover with the chosen folder selected.
    @objc private func wherePopupChanged(_ sender: NSPopUpButton) {
        guard sender.selectedItem?.title == "Other…" else { return }
        pendingRenameName = renameField?.stringValue
        renamePopover?.close()
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = pendingRenameWhere ?? pdfURL.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self = self else { return }
            if resp == .OK, let url = panel.url { self.pendingRenameWhere = url }
            DispatchQueue.main.async { self.renameDocument(nil) }
        }
    }

    @objc private func commitRename(_ sender: Any?) {
        guard let field = renameField, let doc = document as? NSDocument else { return }
        let name = field.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty else { return }
        let folder = (renameWherePopup?.selectedItem?.representedObject as? URL)
            ?? pdfURL.deletingLastPathComponent()
        pendingRenameWhere = nil
        let dest = folder.appendingPathComponent(name + ".pdf")
        guard dest.standardizedFileURL != pdfURL.standardizedFileURL else { renamePopover?.close(); return }
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            infoAlert("Name taken", "A file named “\(dest.lastPathComponent)” already exists in \(folder.lastPathComponent).")
            return
        }
        renamePopover?.close()
        // NSDocument keeps autosave/Versions pointed at the new identity.
        doc.move(to: dest) { [weak self] error in
            if let error = error { infoAlert("Couldn’t rename", error.localizedDescription) }
            self?.layoutTitleAccessory()
        }
    }

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
        if on { setRedact(on: false); setForm(on: false); setErase(on: false) }   // one tool strip at a time
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
        if on { setMarkup(on: false); setForm(on: false); setErase(on: false) }   // one tool strip at a time
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

    // MARK: - Erase mode (whiteout that actually removes — RedactionEngine, white paint)

    @objc func toggleErase(_ sender: Any?) { setErase(on: !eraseOn) }

    private func setErase(on: Bool) {
        guard eraseOn != on, let window = window else { return }
        if on { setMarkup(on: false); setRedact(on: false); setForm(on: false) }
        eraseOn = on
        eraseButton?.state = on ? .on : .off
        pdfView.redactMode = on          // erase rides the redact band machinery
        pdfView.eraseStyle = on
        if on {
            let acc = NSTitlebarAccessoryViewController()
            acc.view = buildEraseStrip(width: window.frame.width)
            acc.layoutAttribute = .bottom
            window.addTitlebarAccessoryViewController(acc)
            eraseAccessory = acc
            updateEraseCount()
        } else {
            eraseAccessory?.removeFromParent()
            eraseAccessory = nil
        }
    }

    private func buildEraseStrip(width: CGFloat) -> NSView {
        let strip = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 40))

        let hint = NSTextField(labelWithString: "Drag over anything to erase it — logos, addresses, images. Erased means removed, not covered.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.frame = NSRect(x: 12, y: 12, width: 620, height: 16)
        strip.addSubview(hint)

        eraseCountLabel.textColor = .secondaryLabelColor
        eraseCountLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        eraseCountLabel.frame = NSRect(x: 640, y: 12, width: 90, height: 16)
        strip.addSubview(eraseCountLabel)

        let clear = NSButton(title: "Clear Marks", target: self, action: #selector(clearEraseMarks))
        clear.bezelStyle = .rounded
        clear.controlSize = .small
        clear.frame = NSRect(x: width - 254, y: 7, width: 100, height: 26)
        clear.autoresizingMask = [.minXMargin]
        strip.addSubview(clear)

        let apply = NSButton(title: "Apply Erase", target: self, action: #selector(applyErase))
        apply.bezelStyle = .rounded
        apply.controlSize = .small
        apply.keyEquivalent = "\r"
        apply.frame = NSRect(x: width - 146, y: 7, width: 134, height: 26)
        apply.autoresizingMask = [.minXMargin]
        strip.addSubview(apply)

        return strip
    }

    private func allEraseMarks() -> [(Int, RedactionAnnotation)] {
        guard let doc = pdfView.document else { return [] }
        var out: [(Int, RedactionAnnotation)] = []
        for i in 0..<doc.pageCount {
            for a in doc.page(at: i)?.annotations.compactMap({ $0 as? RedactionAnnotation }) ?? []
            where a.isErase {
                out.append((i, a))
            }
        }
        return out
    }

    private func updateEraseCount() {
        let n = allEraseMarks().count
        eraseCountLabel.stringValue = n == 0 ? "" : "\(n) mark\(n == 1 ? "" : "s")"
    }

    @objc private func clearEraseMarks() {
        let marks = allEraseMarks()
        guard !marks.isEmpty, let doc = pdfView.document else { return }
        for (_, a) in marks { a.page?.removeAnnotation(a) }
        docUndo.registerUndo(withTarget: self) { me in
            for (i, a) in marks { (me.pdfView.document ?? doc).page(at: i)?.addAnnotation(a) }
            me.docUndo.registerUndo(withTarget: me) { $0.clearEraseMarks() }
            me.updateEraseCount()
            me.pdfView.needsDisplay = true
        }
        docUndo.setActionName("Clear Erase Marks")
        updateEraseCount()
        forceRefresh()
    }

    // Erase is an EDIT, not an export: affected pages are swapped in place (undoable via
    // page identity), autosave persists into the file, Versions is the deep recovery.
    @objc private func applyErase() {
        guard let doc = pdfView.document else { return }
        let marks = allEraseMarks()
        guard !marks.isEmpty else {
            infoAlert("Nothing marked", "Drag over the content you want removed first.")
            return
        }
        var regions: [Int: [CGRect]] = [:]
        for (i, a) in marks { regions[i, default: []].append(a.bounds) }

        // Build every replacement page BEFORE touching the document, and verify each:
        // a rasterized page must carry zero extractable text or nothing is swapped.
        var swaps: [(Int, PDFPage, PDFPage)] = []
        for (i, rects) in regions {
            guard let old = doc.page(at: i),
                  let new = RedactionEngine.destroyedPage(old, regions: rects, style: .erase),
                  (new.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                infoAlert("Erase NOT applied", "Page \(i + 1) couldn't be verified as fully removed — the document was not modified.")
                return
            }
            swaps.append((i, old, new))
        }
        for (_, a) in marks { a.page?.removeAnnotation(a) }   // marks are consumed
        for (i, _, new) in swaps {
            doc.removePage(at: i)
            doc.insert(new, at: i)
        }
        registerPermanentCropUndo(swaps, restoreOld: true, name: "Erase")
        updateEraseCount()
        sidebar.reload()
        forceRefresh()
        setErase(on: false)   // done editing — hand the page back for logo drops etc.
        NSSound(named: "Glass")?.play()
        flashSubtitle("Erased — drop an image to fill the space, ⌘Z to undo")
    }

    // MARK: - Form mode (drag-and-drop fillable fields; Word-simple, AcroForm underneath)

    @objc func toggleForm(_ sender: Any?) { setForm(on: !formOn) }

    private func setForm(on: Bool) {
        guard formOn != on, let window = window else { return }
        if on { setMarkup(on: false); setRedact(on: false); setErase(on: false) }   // one tool strip at a time
        formOn = on
        formButton?.state = on ? .on : .off
        pdfView.formAuthoringOn = on
        if on {
            let acc = NSTitlebarAccessoryViewController()
            acc.view = buildFormStrip(width: window.frame.width)
            acc.layoutAttribute = .bottom
            window.addTitlebarAccessoryViewController(acc)
            formAccessory = acc
            pdfView.formFieldMenuItems = { [weak self] widget in self?.fieldMenuItems(for: widget) ?? [] }
        } else {
            pdfView.armedFieldKind = nil
            formPaletteButtons.forEach { $0.state = .off }
            fieldPopover?.close()
            formAccessory?.removeFromParent()
            formAccessory = nil
        }
    }

    private static let formPalette: [(String, String)] = [
        ("Text Field", "character.cursor.ibeam"), ("Text Box", "text.justify.left"),
        ("Checkbox", "checkmark.square"), ("Multiple Choice", "circle.circle"),
        ("Dropdown", "chevron.down.square"), ("Date", "calendar")]

    private func buildFormStrip(width: CGFloat) -> NSView {
        let strip = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        formPaletteButtons = []
        var x: CGFloat = 12
        for (i, entry) in Self.formPalette.enumerated() {
            let btn = NSButton(title: entry.0, target: self, action: #selector(fieldToolPicked(_:)))
            btn.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: entry.0)
            btn.imagePosition = .imageLeading
            btn.setButtonType(.pushOnPushOff)
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            btn.tag = i
            let w = btn.intrinsicContentSize.width + 14
            btn.frame = NSRect(x: x, y: 7, width: w, height: 26)
            strip.addSubview(btn)
            formPaletteButtons.append(btn)
            x += w + 6
        }
        let hint = NSTextField(labelWithString: "Pick a field, then click the page to place it — drag fields to move, right-click to edit")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.alignment = .right
        hint.frame = NSRect(x: width - 472, y: 12, width: 456, height: 16)
        hint.autoresizingMask = [.minXMargin]
        strip.addSubview(hint)
        return strip
    }

    private func fieldKind(forTag tag: Int) -> FormFieldKind {
        switch tag {
        case 1: return .multiline
        case 2: return .checkbox
        case 3: return .radioGroup(options: ["Option 1", "Option 2", "Option 3"])
        case 4: return .dropdown(options: ["Option 1", "Option 2", "Option 3"])
        case 5: return .date
        default: return .text
        }
    }

    @objc private func fieldToolPicked(_ sender: NSButton) {
        formPaletteButtons.forEach { if $0 !== sender { $0.state = .off } }
        pdfView.armedFieldKind = sender.state == .on ? fieldKind(forTag: sender.tag) : nil
    }

    // From SigningPDFView: click/drag committed. A bare click arrives tiny — give defaults.
    func formFieldPlaced(kind: FormFieldKind, rect: CGRect, page: PDFPage) {
        guard let doc = pdfView.document else { return }
        var r = rect
        let defaults: CGSize
        switch kind {
        case .text: defaults = CGSize(width: 200, height: 24)
        case .multiline: defaults = CGSize(width: 300, height: 72)
        case .checkbox: defaults = CGSize(width: 18, height: 18)
        case .radioGroup: defaults = CGSize(width: 16, height: 22)
        case .dropdown: defaults = CGSize(width: 200, height: 24)
        case .date: defaults = CGSize(width: 120, height: 24)
        }
        if r.width < 20 || r.height < 12 {
            // Click-place: the point is the field's top-left.
            r = CGRect(x: r.origin.x, y: r.origin.y - defaults.height, width: defaults.width, height: defaults.height)
        }
        let name = FormFieldEngine.uniqueName(base: kind.baseName, in: doc)
        let anns = FormFieldEngine.makeAnnotations(kind: kind, name: name, bounds: r)
        let labels = FormFieldEngine.makeLabels(kind: kind, name: name, widgets: anns)
        (anns + labels).forEach { page.addAnnotation($0) }
        registerAnnotationRemovalUndo((anns + labels).map { (page, $0) }, name: "Add Field")
        forceRefresh()
        switch kind {
        case .radioGroup, .dropdown:
            openFieldEditor(named: name)   // options matter — offer the editor right away
        default: break
        }
    }

    func fieldMoved(_ items: [(PDFAnnotation, CGRect)]) {
        registerFieldMoveUndo(items, name: "Move Field")
        forceRefresh()
    }

    // A dropped image lands centered on the drop point as a movable, resizable stamp —
    // exactly the signature machinery, so drag/resize/remove/undo all come free.
    func imageDropped(_ image: NSImage, at point: CGPoint, on page: PDFPage) {
        let box = page.bounds(for: .mediaBox)
        let width = min(180, box.width * 0.35, max(40, image.size.width))
        let aspect = image.size.height <= 0 ? 1 : image.size.width / image.size.height
        let height = width / max(0.01, aspect)
        let origin = CGPoint(x: min(max(point.x - width / 2, box.minX), box.maxX - width),
                             y: min(max(point.y - height / 2, box.minY), box.maxY - height))
        let ann = ImageStampAnnotation(image: image, bounds: CGRect(origin: origin, size: CGSize(width: width, height: height)))
        addStamp(ann, to: page)
        didSelect(ann)
        forceRefresh()
        flashSubtitle("Image placed — drag to move, ⌘Z to undo")
    }

    private func registerFieldMoveUndo(_ items: [(PDFAnnotation, CGRect)], name: String) {
        docUndo.registerUndo(withTarget: self) { me in
            let current = items.map { ($0.0, $0.0.bounds) }
            items.forEach { $0.0.bounds = $0.1 }
            me.registerFieldMoveUndo(current, name: name)
            me.forceRefresh()
        }
        docUndo.setActionName(name)
    }

    private func groupWidgets(named name: String) -> [(PDFPage, PDFAnnotation)] {
        guard let doc = pdfView.document else { return [] }
        var out: [(PDFPage, PDFAnnotation)] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where a.type == "Widget" && a.fieldName == name { out.append((page, a)) }
        }
        return out
    }

    /// Widgets AND their caption labels — what Remove / rebuild must act on.
    private func groupAnnotations(named name: String) -> [(PDFPage, PDFAnnotation)] {
        guard let doc = pdfView.document else { return [] }
        var out: [(PDFPage, PDFAnnotation)] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations
            where (a.type == "Widget" && a.fieldName == name) || FormFieldEngine.isLabel(a, for: name) {
                out.append((page, a))
            }
        }
        return out
    }

    private func fieldMenuItems(for widget: PDFAnnotation) -> [NSMenuItem] {
        guard let name = widget.fieldName else { return [] }
        let edit = NSMenuItem(title: "Edit Field…", action: #selector(editFieldFromMenu(_:)), keyEquivalent: "")
        edit.target = self; edit.representedObject = name
        let remove = NSMenuItem(title: "Remove Field", action: #selector(removeFieldFromMenu(_:)), keyEquivalent: "")
        remove.target = self; remove.representedObject = name
        return [edit, remove]
    }

    @objc private func editFieldFromMenu(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { openFieldEditor(named: name) }
    }

    @objc private func removeFieldFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let items = groupAnnotations(named: name)
        guard !items.isEmpty else { return }
        items.forEach { $0.0.removeAnnotation($0.1) }
        registerAnnotationAddUndo(items, name: "Remove Field")
        forceRefresh()
    }

    // MARK: Field editor popover (name + options)

    private func openFieldEditor(named name: String) {
        let widgets = groupWidgets(named: name)
        guard let first = widgets.first else { return }
        editingFieldName = name
        let isRadio = first.1.widgetControlType == .radioButtonControl
        let isChoice = first.1.widgetFieldType == .choice
        let hasOptions = isRadio || isChoice

        let content = NSViewController()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: hasOptions ? 208 : 108))
        content.view = v   // frame BEFORE populating — zero-frame containers fling children

        let nameLabel = NSTextField(labelWithString: "Field name")
        nameLabel.font = .systemFont(ofSize: 11); nameLabel.textColor = .secondaryLabelColor
        nameLabel.frame = NSRect(x: 14, y: v.frame.height - 26, width: 160, height: 16)
        v.addSubview(nameLabel)
        let nameField = NSTextField(string: name)
        nameField.font = .systemFont(ofSize: 13)
        nameField.frame = NSRect(x: 14, y: v.frame.height - 52, width: 232, height: 24)
        v.addSubview(nameField)
        fieldNameField = nameField

        if hasOptions {
            let optLabel = NSTextField(labelWithString: "Options — one per line")
            optLabel.font = .systemFont(ofSize: 11); optLabel.textColor = .secondaryLabelColor
            optLabel.frame = NSRect(x: 14, y: v.frame.height - 76, width: 200, height: 16)
            v.addSubview(optLabel)
            let scroll = NSScrollView(frame: NSRect(x: 14, y: 48, width: 232, height: v.frame.height - 130))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let tv = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
            tv.font = .systemFont(ofSize: 13)
            tv.isRichText = false
            tv.autoresizingMask = [.width]
            let options: [String]
            if isChoice {
                options = first.1.choices ?? []
            } else {
                options = widgets.map { $0.1.buttonWidgetStateString.replacingOccurrences(of: "_", with: " ") }
            }
            tv.string = options.joined(separator: "\n")
            scroll.documentView = tv
            v.addSubview(scroll)
            fieldOptionsView = tv
        }

        let done = NSButton(title: "Done", target: self, action: #selector(commitFieldEdit(_:)))
        done.bezelStyle = .rounded; done.controlSize = .small
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: v.frame.width - 78, y: 12, width: 64, height: 26)
        v.addSubview(done)
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeFieldFromEditor(_:)))
        remove.bezelStyle = .rounded; remove.controlSize = .small
        remove.frame = NSRect(x: 14, y: 12, width: 76, height: 26)
        v.addSubview(remove)

        let pop = NSPopover()
        pop.contentViewController = content
        pop.behavior = .transient
        fieldPopover = pop
        // Anchor on the topmost widget of the group, in view space.
        let anchor = widgets.max(by: { $0.1.bounds.maxY < $1.1.bounds.maxY }) ?? first
        let viewRect = pdfView.convert(anchor.1.bounds, from: anchor.0)
        pop.show(relativeTo: viewRect, of: pdfView, preferredEdge: .maxY)
        pop.contentViewController?.view.window?.makeFirstResponder(nameField)
    }

    @objc private func removeFieldFromEditor(_ sender: Any?) {
        fieldPopover?.close()
        guard let name = editingFieldName else { return }
        let items = groupAnnotations(named: name)
        guard !items.isEmpty else { return }
        items.forEach { $0.0.removeAnnotation($0.1) }
        registerAnnotationAddUndo(items, name: "Remove Field")
        forceRefresh()
    }

    @objc private func commitFieldEdit(_ sender: Any?) {
        defer { fieldPopover?.close() }
        guard let doc = pdfView.document, let oldName = editingFieldName else { return }
        let widgets = groupWidgets(named: oldName)
        guard let first = widgets.first else { return }
        var newName = (fieldNameField?.stringValue ?? oldName).trimmingCharacters(in: .whitespaces)
        if newName.isEmpty { newName = oldName }
        if newName != oldName, groupWidgets(named: newName).isEmpty == false {
            newName = FormFieldEngine.uniqueName(base: newName, in: doc)   // avoid silent merges
        }
        let newOptions = (fieldOptionsView?.string.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) ?? []

        let isRadio = first.1.widgetControlType == .radioButtonControl
        let isChoice = first.1.widgetFieldType == .choice
        if isRadio {
            let oldOptions = widgets.map { $0.1.buttonWidgetStateString.replacingOccurrences(of: "_", with: " ") }
            if !newOptions.isEmpty, newOptions != oldOptions || newName != oldName {
                // Rebuild the group (widgets + captions) anchored where the old one started.
                let page = first.0
                let old = groupAnnotations(named: oldName)
                let minX = widgets.map { $0.1.bounds.minX }.min() ?? first.1.bounds.minX
                let topY = widgets.map { $0.1.bounds.maxY }.max() ?? first.1.bounds.maxY
                docUndo.beginUndoGrouping()
                old.forEach { $0.0.removeAnnotation($0.1) }
                registerAnnotationAddUndo(old, name: "Edit Field")
                let kind = FormFieldKind.radioGroup(options: newOptions)
                let anns = FormFieldEngine.makeAnnotations(kind: kind, name: newName,
                                                           bounds: CGRect(x: minX, y: topY - 22, width: 16, height: 22))
                let labels = FormFieldEngine.makeLabels(kind: kind, name: newName, widgets: anns)
                (anns + labels).forEach { page.addAnnotation($0) }
                registerAnnotationRemovalUndo((anns + labels).map { (page, $0) }, name: "Edit Field")
                docUndo.endUndoGrouping()
            }
        } else {
            if isChoice, !newOptions.isEmpty { first.1.choices = newOptions }
            if newName != oldName {
                widgets.forEach { $0.1.fieldName = newName }
                // Captions carry the name — keep text and the /NM link in step.
                for (_, a) in groupAnnotations(named: oldName) where FormFieldEngine.isLabel(a) {
                    a.contents = newName
                    a.userName = FormFieldEngine.labelName(for: newName)
                }
            }
            docUndo.registerUndo(withTarget: self) { _ in }   // dirty the document for autosave
            docUndo.setActionName("Edit Field")
        }
        forceRefresh()
        editingFieldName = nil
    }

    // From SigningPDFView after a rubber-band gesture: the mark exists — make it undoable
    // and force the repaint (PDFView's page cache doesn't reliably show annotation adds).
    func redactionAdded(_ ann: RedactionAnnotation) {
        docUndo.registerUndo(withTarget: self) { $0.removeRedactionMark(ann) }
        docUndo.setActionName("Mark Redaction")
        updateRedactCount()
        updateEraseCount()
        forceRefresh()
    }

    private func addRedactionMark(_ ann: RedactionAnnotation, to page: PDFPage, refresh: Bool = true) {
        page.addAnnotation(ann)
        docUndo.registerUndo(withTarget: self) { $0.removeRedactionMark(ann) }
        docUndo.setActionName("Mark Redaction")
        updateRedactCount()
        updateEraseCount()
        if refresh { forceRefresh() }
    }

    private func removeRedactionMark(_ ann: RedactionAnnotation) {
        guard let page = ann.page else { return }
        page.removeAnnotation(ann)
        docUndo.registerUndo(withTarget: self) { $0.addRedactionMark(ann, to: page) }
        docUndo.setActionName("Mark Redaction")
        updateRedactCount()
        updateEraseCount()
        forceRefresh()   // custom-annotation removal needs a forced repaint
    }

    private func allRedactionMarks() -> [(Int, RedactionAnnotation)] {
        guard let doc = pdfView.document else { return [] }
        var out: [(Int, RedactionAnnotation)] = []
        for i in 0..<doc.pageCount {
            for a in doc.page(at: i)?.annotations.compactMap({ $0 as? RedactionAnnotation }) ?? []
            where !a.isErase {
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
                addRedactionMark(RedactionAnnotation(bounds: r), to: page, refresh: false)
            }
        }
        redactedTerms.insert(term)
        redactTermField.stringValue = ""
        forceRefresh()
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

    // v2.5: Apply Redactions is an EDIT, not an export — the same discipline as Apply Erase.
    // Every replacement page is built and VERIFIED to carry zero extractable text BEFORE the
    // document is touched; a single failure leaves the document completely unmodified. The
    // verification certificate is emitted at SAVE time, so it hashes the file actually shipped
    // rather than an intermediate the user never sees.
    @objc private func applyRedactions() {
        guard let doc = pdfView.document else { return }
        let marks = allRedactionMarks()
        guard !marks.isEmpty else {
            infoAlert("Nothing marked", "Drag over content (or use \u{201C}Redact every occurrence of\u{2026}\u{201D}) to mark it first.")
            return
        }
        var regions: [Int: [CGRect]] = [:]
        for (i, a) in marks { regions[i, default: []].append(a.bounds) }

        var swaps: [(Int, PDFPage, PDFPage)] = []
        for (i, rects) in regions.sorted(by: { $0.key < $1.key }) {
            guard let old = doc.page(at: i),
                  let new = RedactionEngine.destroyedPage(old, regions: rects, style: .blackout),
                  (new.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                infoAlert("Redaction NOT applied",
                          "Page \(i + 1) couldn\u{2019}t be verified as fully removed — the document was not modified.")
                return
            }
            swaps.append((i, old, new))
        }

        for (_, a) in marks { a.page?.removeAnnotation(a) }   // marks are consumed
        for (i, _, new) in swaps {
            doc.removePage(at: i)
            doc.insert(new, at: i)
        }

        let pages = swaps.map { $0.0 }
        // One ⌘Z undoes the page swap AND the certificate log together.
        docUndo.beginUndoGrouping()
        registerPermanentCropUndo(swaps, restoreOld: true, name: "Redact")
        registerRedactionLogUndo(pages: pages, regions: marks.count, adding: true)
        docUndo.endUndoGrouping()
        redactedPageLog.formUnion(pages)
        redactedRegionCount += marks.count

        updateRedactCount()
        sidebar.reload()
        forceRefresh()
        setRedact(on: false)
        NSSound(named: "Glass")?.play()
        let n = pages.count
        flashSubtitle("Redacted \(n) page\(n == 1 ? "" : "s") — 0 recoverable characters. ⌘S to save; a certificate saves alongside.")
    }

    // Keeps the certificate log in step with undo/redo, so ⌘Z after a redaction does not leave
    // Jack claiming a redaction the document no longer carries.
    private func registerRedactionLogUndo(pages: [Int], regions: Int, adding: Bool) {
        docUndo.registerUndo(withTarget: self) { me in
            if adding {
                me.redactedPageLog.subtract(pages)
                me.redactedRegionCount = max(0, me.redactedRegionCount - regions)
            } else {
                me.redactedPageLog.formUnion(pages)
                me.redactedRegionCount += regions
            }
            me.registerRedactionLogUndo(pages: pages, regions: regions, adding: !adding)
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
        panel.nameFieldStringValue = exportBaseName + "-clean.pdf"
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
                var locked = false
                if RedactionEngine.apply(doc, redactions: [:], to: tmp), let flat = PDFDocument(url: tmp) {
                    locked = AES256PDF.encrypt(flat, to: out, userPassword: password, ownerPassword: password)
                }
                ok = locked
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
        panel.nameFieldStringValue = exportBaseName + "-pages.pdf"
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

    // Dirty state and autosave flow from undo registrations on the document's undo manager.
    private func markEdited() {}

    private func forceRefresh() {
        let page = pdfView.currentPage
        let doc = pdfView.document
        pdfView.document = nil
        pdfView.document = doc
        if let page = page, page.document != nil { pdfView.go(to: page) }
        pageChanged()
    }

    // MARK: - Save (flatten stamps + form values, keep the original file untouched)

    @objc func exportFlattened(_ sender: Any?) {
        guard let doc = pdfView.document, let window = window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportBaseName + "-flattened.pdf"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let out = panel.url, let self = self else { return }
            if self.exportCurrentState(doc, to: out) {
                NSWorkspace.shared.activateFileViewerSelecting([out])
                NSSound(named: "Glass")?.play()
            } else {
                infoAlert("Save failed", "Couldn’t write the PDF.")
            }
        }
    }

    // Everything Save/Share exports: content + stamps flattened, comments carried as live notes.
    private func exportCurrentState(_ doc: PDFDocument, to out: URL) -> Bool {
        let comments = collectComments()
        if comments.isEmpty { return flatten(doc, to: out) }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jack-save-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard flatten(doc, to: tmp), let flat = PDFDocument(url: tmp) else { return false }
        for (i, a) in comments {
            // Standard PDF note so Acrobat/Preview show a clickable comment.
            let copy = PDFAnnotation(bounds: a.bounds, forType: .text, withProperties: nil)
            copy.contents = a.contents
            copy.color = NSColor.systemYellow
            flat.page(at: i)?.addAnnotation(copy)
        }
        return flat.write(to: out)
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

            // Pending redaction marks must never bake in as cosmetic boxes, and comment notes
            // are re-added as live annotations after flattening — strip both before drawing.
            let overlays = page.annotations.filter { $0 is RedactionAnnotation || Self.isComment($0) }
            overlays.forEach { page.removeAnnotation($0) }

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
            overlays.forEach { page.addAnnotation($0) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return true
    }

    // MARK: - Text annotations (highlight / underline / strikethrough), undoable

    static let highlightColors: [(name: String, color: NSColor)] = [
        ("Yellow", .systemYellow), ("Green", .systemGreen), ("Blue", .systemBlue),
        ("Pink", .systemPink), ("Purple", .systemPurple)
    ]

    static func swatch(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 14, height: 14))
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 12, height: 12)).fill()
        img.unlockFocus()
        return img
    }

    private var savedHighlightColor: NSColor {
        let i = UserDefaults.standard.integer(forKey: "jack.highlightColor")
        return Self.highlightColors[(0..<Self.highlightColors.count).contains(i) ? i : 0].color
    }

    // ⇧⌘H and the Edit menu use the last color picked from the toolbar dropdown.
    @objc func highlightSelection(_ sender: Any?) { annotateSelection(.highlight, color: savedHighlightColor, name: "Highlight") }

    @objc func highlightColorPicked(_ sender: NSMenuItem) {
        let i = (0..<Self.highlightColors.count).contains(sender.tag) ? sender.tag : 0
        UserDefaults.standard.set(i, forKey: "jack.highlightColor")
        annotateSelection(.highlight, color: Self.highlightColors[i].color, name: "Highlight")
    }
    @objc func underlineSelection(_ sender: Any?) { annotateSelection(.underline, color: .systemBlue, name: "Underline") }
    @objc func strikethroughSelection(_ sender: Any?) { annotateSelection(.strikeOut, color: .systemRed, name: "Strikethrough") }

    private func annotateSelection(_ type: PDFAnnotationSubtype, color: NSColor, name: String) {
        let live = pdfView.currentSelection
        let liveOK = !((live?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        guard let sel = liveOK ? live : lastSelection else {
            infoAlert("Nothing selected", "Select some text first, then \(name.lowercased()) it.")
            return
        }
        var added: [(PDFPage, PDFAnnotation)] = []
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                guard b.width > 0, b.height > 0 else { continue }
                let a = PDFAnnotation(bounds: b, forType: type, withProperties: nil)
                a.color = color
                a.quadrilateralPoints = [
                    NSValue(point: NSPoint(x: 0, y: b.height)), NSValue(point: NSPoint(x: b.width, y: b.height)),
                    NSValue(point: NSPoint(x: 0, y: 0)), NSValue(point: NSPoint(x: b.width, y: 0))
                ]
                page.addAnnotation(a)
                added.append((page, a))
            }
        }
        guard !added.isEmpty else { return }
        pdfView.setCurrentSelection(nil, animate: false)
        lastSelection = nil
        registerAnnotationRemovalUndo(added, name: name)
        markEdited()
        forceRefresh()
    }

    // Context-menu items for a right-click in the page (built fresh each time).
    private final class NoteTarget {
        let page: PDFPage; let point: CGPoint
        init(_ p: PDFPage, _ pt: CGPoint) { page = p; point = pt }
    }

    private func buildAnnotateMenuItems(page: PDFPage?, point: CGPoint) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let live = pdfView.currentSelection
        let hasSel = !((live?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || lastSelection != nil
        if hasSel {
            for (i, entry) in Self.highlightColors.enumerated() {
                let m = NSMenuItem(title: "Highlight \(entry.name)", action: #selector(highlightColorPicked(_:)), keyEquivalent: "")
                m.target = self; m.tag = i; m.image = Self.swatch(entry.color)
                items.append(m)
            }
            let u = NSMenuItem(title: "Underline", action: #selector(underlineSelection(_:)), keyEquivalent: "")
            u.target = self; u.image = Self.swatch(.systemBlue)
            items.append(u)
            let s = NSMenuItem(title: "Strikethrough", action: #selector(strikethroughSelection(_:)), keyEquivalent: "")
            s.target = self; s.image = Self.swatch(.systemRed)
            items.append(s)
        }
        if hasSel {
            let c = NSMenuItem(title: "Add Comment to Selection…", action: #selector(addComment(_:)), keyEquivalent: "")
            c.target = self
            c.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Add Comment")
            items.append(c)
        } else if let page = page {
            let c = NSMenuItem(title: "Add Comment Here…", action: #selector(addCommentFromMenu(_:)), keyEquivalent: "")
            c.target = self
            c.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Add Comment")
            c.representedObject = NoteTarget(page, point)
            items.append(c)
        }
        return items
    }

    // MARK: - Comments (sticky notes) — click to read, editable, survive Save as real notes

    private var notePopover: NSPopover?

    // A text-anchored comment is a highlight + a note-icon badge; they act as one.
    private var commentPartners: [ObjectIdentifier: PDFAnnotation] = [:]
    private func link(_ a: PDFAnnotation, _ b: PDFAnnotation) {
        commentPartners[ObjectIdentifier(a)] = b
        commentPartners[ObjectIdentifier(b)] = a
    }
    private func partner(of a: PDFAnnotation) -> PDFAnnotation? { commentPartners[ObjectIdentifier(a)] }

    // In-app, a comment IS its badge; the linked highlight is just a visual anchor.
    static func isComment(_ ann: PDFAnnotation) -> Bool { ann is CommentBadgeAnnotation }

    @objc private func addCommentFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? NoteTarget else { return }
        addComment(on: target.page, at: target.point)
    }

    // Toolbar / ⇧⌘C / context-menu-with-selection: attach the comment to the selected text
    // (Adobe's "add note to text"). Without a selection, guide to the right-click placement.
    @objc func addComment(_ sender: Any?) {
        let live = pdfView.currentSelection
        let liveOK = !((live?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        guard let sel = liveOK ? live : lastSelection else {
            infoAlert("Where should the comment go?",
                      "Select the text you want to comment on, or right-click a spot on the page and choose “Add Comment Here…”.")
            return
        }
        guard let text = promptForCommentText(initial: "") else { return }
        var added: [(PDFPage, PDFAnnotation)] = []
        for page in sel.pages {
            let b = sel.bounds(for: page)
            guard b.width > 0, b.height > 0 else { continue }
            // One highlight annotation per page, quads per line, carrying the note.
            var quads: [NSValue] = []
            for line in sel.selectionsByLine() where line.pages.contains(page) {
                let lb = line.bounds(for: page)
                let o = b.origin
                quads += [
                    NSValue(point: NSPoint(x: lb.minX - o.x, y: lb.maxY - o.y)),
                    NSValue(point: NSPoint(x: lb.maxX - o.x, y: lb.maxY - o.y)),
                    NSValue(point: NSPoint(x: lb.minX - o.x, y: lb.minY - o.y)),
                    NSValue(point: NSPoint(x: lb.maxX - o.x, y: lb.minY - o.y))
                ]
            }
            // The highlight is purely visual — the note itself lives in the badge.
            let ann = PDFAnnotation(bounds: b, forType: .highlight, withProperties: nil)
            ann.color = .systemYellow
            if !quads.isEmpty { ann.quadrilateralPoints = quads }
            page.addAnnotation(ann)
            added.append((page, ann))

            let box = page.bounds(for: .mediaBox)
            let size: CGFloat = 18
            let badge = CommentBadgeAnnotation(
                bounds: CGRect(x: min(b.maxX + 3, box.maxX - size - 2),
                               y: min(b.maxY + 2, box.maxY - size - 2),
                               width: size, height: size),
                text: text)
            page.addAnnotation(badge)
            link(ann, badge)
            added.append((page, badge))
        }
        guard !added.isEmpty else { return }
        pdfView.setCurrentSelection(nil, animate: false)
        lastSelection = nil
        registerAnnotationRemovalUndo(added, name: "Add Comment")
        markEdited()
        forceRefresh()
    }

    private func addComment(on page: PDFPage, at point: CGPoint) {
        guard let text = promptForCommentText(initial: "") else { return }
        let size: CGFloat = 18
        let box = page.bounds(for: .mediaBox)
        let ann = CommentBadgeAnnotation(
            bounds: CGRect(x: min(max(point.x - size / 2, box.minX + 2), box.maxX - size - 2),
                           y: min(max(point.y - size / 2, box.minY + 2), box.maxY - size - 2),
                           width: size, height: size),
            text: text)
        page.addAnnotation(ann)
        registerAnnotationRemovalUndo([(page, ann)], name: "Add Comment")
        markEdited()
        forceRefresh()
    }

    private func promptForCommentText(initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = initial.isEmpty ? "Add Comment" : "Edit Comment"
        alert.informativeText = "Comments stay editable in the saved PDF."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
        let tv = NSTextView(frame: scroll.bounds)
        tv.font = .systemFont(ofSize: 13)
        tv.string = initial
        tv.isRichText = false
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: initial.isEmpty ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = tv
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func noteClicked(_ ann: PDFAnnotation) {
        guard let page = ann.page, let _ = window else { return }
        notePopover?.close()

        let vc = NSViewController()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 140))
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 44, width: 276, height: 84))
        let tv = NSTextView(frame: scroll.bounds)
        tv.string = ann.contents ?? ""
        tv.font = .systemFont(ofSize: 13)
        tv.isEditable = false
        tv.drawsBackground = false
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        v.addSubview(scroll)

        let edit = NSButton(title: "Edit…", target: self, action: #selector(editNote(_:)))
        edit.bezelStyle = .rounded; edit.controlSize = .small
        edit.frame = NSRect(x: 12, y: 10, width: 70, height: 26)
        v.addSubview(edit)
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeNote(_:)))
        remove.bezelStyle = .rounded; remove.controlSize = .small
        remove.frame = NSRect(x: 88, y: 10, width: 80, height: 26)
        v.addSubview(remove)
        vc.view = v

        // Hand the annotation to the buttons via the popover's ivar.
        activeNote = ann
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        let rect = pdfView.convert(ann.bounds, from: page)
        pop.show(relativeTo: rect, of: pdfView, preferredEdge: .maxY)
        notePopover = pop
    }

    private weak var activeNote: PDFAnnotation?

    @objc private func editNote(_ sender: Any?) {
        guard let ann = activeNote else { return }
        notePopover?.close()
        guard let text = promptForCommentText(initial: ann.contents ?? "") else { return }
        let old = ann.contents ?? ""
        ann.contents = text
        docUndo.registerUndo(withTarget: self) { me in
            ann.contents = old
            me.docUndo.registerUndo(withTarget: me) { _ in ann.contents = text }
        }
        docUndo.setActionName("Edit Comment")
        markEdited()
    }

    @objc private func removeNote(_ sender: Any?) {
        guard let ann = activeNote else { return }
        notePopover?.close()
        var items: [(PDFPage, PDFAnnotation)] = []
        for a in [ann, partner(of: ann)].compactMap({ $0 }) {
            if let page = a.page { page.removeAnnotation(a); items.append((page, a)) }
        }
        guard !items.isEmpty else { return }
        registerAnnotationAddUndo(items, name: "Remove Comment")
        markEdited()
        forceRefresh()
    }

    private func collectComments() -> [(Int, PDFAnnotation)] {
        guard let doc = pdfView.document else { return [] }
        var out: [(Int, PDFAnnotation)] = []
        for i in 0..<doc.pageCount {
            for a in doc.page(at: i)?.annotations.filter({ Self.isComment($0) }) ?? [] { out.append((i, a)) }
        }
        return out
    }

    // Mutually recursive add/remove so redo comes free.
    private func registerAnnotationRemovalUndo(_ items: [(PDFPage, PDFAnnotation)], name: String) {
        docUndo.registerUndo(withTarget: self) { me in
            items.forEach { $0.0.removeAnnotation($0.1) }
            me.registerAnnotationAddUndo(items, name: name)
            me.markEdited(); me.forceRefresh()
        }
        docUndo.setActionName(name)
    }
    private func registerAnnotationAddUndo(_ items: [(PDFPage, PDFAnnotation)], name: String) {
        docUndo.registerUndo(withTarget: self) { me in
            items.forEach { $0.0.addAnnotation($0.1) }
            me.registerAnnotationRemovalUndo(items, name: name)
            me.markEdited(); me.forceRefresh()
        }
        docUndo.setActionName(name)
    }

    // MARK: - Snapshot & Crop

    /// Transient status under the title, restored to the page indicator after a beat.
    private func flashSubtitle(_ text: String) {
        subtitleLabel.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.pageChanged() }
    }

    // One pasteboard item carrying EVERY flavor a paste target can want:
    // - PNG + TIFF + original JPEG data → Mail, Word, Notes, browsers
    // - a real file on disk + its file-URL flavor → Finder/Desktop paste works too
    //   (image data alone leaves Finder's Paste greyed out — the classic complaint)
    // Then a read-back self-check: if the write didn't land, SAY so.
    // Remove Object: delete this one image and leave the rest of the page exactly as drawn —
    // background, text layer and all. Erase is the fallback for anything that is not a discrete
    // object (a region of a photo, a scanned page), and the alert says so when this can't run.
    @objc private func removeHitObject(_ sender: Any?) {
        guard let (hit, page) = lastImageHit, let doc = pdfView.document else { return }
        let index = doc.index(for: page)
        guard index != NSNotFound else { return }

        // The engine returns nil unless it can PROVE the image object left the file, so a
        // non-nil result is the guarantee — there is nothing to re-check here.
        guard let cleaned = ObjectRemovalEngine.removing(hit, from: page) else {
            infoAlert("Couldn’t remove this object",
                      "This image couldn’t be removed on its own — it may be used more than once on the page, "
                      + "or be part of a scanned page rather than a separate object.\n\nUse Erase to remove it "
                      + "as a region instead. Nothing was changed.")
            return
        }

        doc.removePage(at: index)
        doc.insert(cleaned, at: index)
        registerPermanentCropUndo([(index, page, cleaned)], restoreOld: true, name: "Remove Object")
        lastImageHit = nil
        sidebar.reload()
        forceRefresh()
        NSSound(named: "Glass")?.play()
        flashSubtitle("Object removed — background and text untouched, ⌘Z to undo")
    }

    @objc private func copyHitImage(_ sender: Any?) {
        guard let (hit, page) = lastImageHit,
              let img = ImageHitEngine.extract(hit, from: page),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            infoAlert("Couldn't copy image", "This image couldn't be extracted from the PDF.")
            return
        }

        // A pasted file needs to exist when Finder resolves it — keep copies in Jack's
        // cache and prune anything older than a week.
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jack/Clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if let old = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.creationDateKey]) {
            for u in old {
                if let d = (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                   d < Date(timeIntervalSinceNow: -7 * 86400) {
                    try? FileManager.default.removeItem(at: u)
                }
            }
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let ext = hit.jpegData != nil ? "jpg" : "png"
        let fileURL = cacheDir.appendingPathComponent("Jack Image \(df.string(from: Date())).\(ext)")
        try? (hit.jpegData ?? png).write(to: fileURL)

        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        if let jpeg = hit.jpegData { item.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg")) }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            item.setString(fileURL.absoluteString, forType: .fileURL)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        let wrote = pb.writeObjects([item])

        // Trust nothing: confirm the clipboard actually holds what we just wrote.
        if !wrote || pb.data(forType: .png) == nil {
            infoAlert("Copy didn't reach the clipboard",
                      "Something on this Mac (often a clipboard manager) blocked the copy. The image was saved instead — you can drag it from there.")
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return
        }
        NSSound(named: "Pop")?.play()
        flashSubtitle("Image copied — paste into any app or folder")
    }

    @objc private func saveHitImage(_ sender: Any?) {
        guard let (hit, page) = lastImageHit, let window,
              let (data, ext) = ImageHitEngine.fileData(hit, from: page) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportBaseName + "-image.\(ext)"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = ext == "jpg" ? [.jpeg] : [.png] }
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let out = panel.url else { return }
            try? data.write(to: out)
            NSWorkspace.shared.activateFileViewerSelecting([out])
        }
    }

    @objc func copyRegionAsImage(_ sender: Any?) {
        flashSubtitle("Drag over the region to copy…")
        pdfView.regionColor = .systemTeal
        pdfView.regionAction = { [weak self] rect, page in
            guard let img = CropEngine.snapshotImage(page: page, region: rect) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([img])
            NSSound(named: "Pop")?.play()
            self?.flashSubtitle("Region copied — paste anywhere")
        }
    }

    @objc func saveRegionAsImage(_ sender: Any?) {
        flashSubtitle("Drag over the region to save…")
        pdfView.regionColor = .systemTeal
        pdfView.regionAction = { [weak self] rect, page in
            guard let self, let window = self.window,
                  let img = CropEngine.snapshotImage(page: page, region: rect),
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = self.exportBaseName + "-region.png"
            panel.directoryURL = self.pdfURL.deletingLastPathComponent()
            if #available(macOS 11.0, *) { panel.allowedContentTypes = [.png] }
            panel.beginSheetModal(for: window) { resp in
                guard resp == .OK, let out = panel.url else { return }
                try? png.write(to: out)
                NSWorkspace.shared.activateFileViewerSelecting([out])
            }
        }
    }

    @objc func cropPages(_ sender: Any?) {
        flashSubtitle("Drag the area to keep…")
        pdfView.regionColor = .systemBlue
        pdfView.regionAction = { [weak self] rect, page in
            self?.runCropDialog(rect: rect, page: page)
        }
    }

    private func runCropDialog(rect: CGRect, page: PDFPage) {
        guard let doc = pdfView.document else { return }
        let alert = NSAlert()
        alert.messageText = "Crop Pages"
        alert.informativeText = "Standard crop hides everything outside the area — it's reversible, and the hidden content stays in the file. Permanent crop re-renders the page so what's outside is verifiably gone (the page becomes an image)."
        let acc = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        let scope = NSPopUpButton(frame: NSRect(x: 0, y: 32, width: 200, height: 25))
        scope.addItems(withTitles: ["This page only", "All pages"])
        acc.addSubview(scope)
        let permanent = NSButton(checkboxWithTitle: "Permanent — remove content outside the crop", target: nil, action: nil)
        permanent.frame = NSRect(x: 0, y: 4, width: 320, height: 20)
        acc.addSubview(permanent)
        alert.accessoryView = acc
        alert.addButton(withTitle: "Crop")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { pageChanged(); return }

        let pageIndexes: [Int]
        if scope.indexOfSelectedItem == 1 {
            pageIndexes = Array(0..<doc.pageCount)
        } else {
            pageIndexes = [doc.index(for: page)]
        }
        if permanent.state == .on {
            applyPermanentCrop(rect: rect, pages: pageIndexes, in: doc)
        } else {
            applyStandardCrop(rect: rect, pages: pageIndexes, in: doc)
        }
        pageChanged()
    }

    private func applyStandardCrop(rect: CGRect, pages: [Int], in doc: PDFDocument) {
        var items: [(PDFPage, CGRect)] = []
        for i in pages {
            guard let p = doc.page(at: i) else { continue }
            let clipped = rect.intersection(p.bounds(for: .mediaBox))
            guard !clipped.isEmpty else { continue }
            items.append((p, p.bounds(for: .cropBox)))
            p.setBounds(clipped, for: .cropBox)
        }
        guard !items.isEmpty else { return }
        registerCropUndo(items, name: "Crop Pages")
        sidebar.reload()
        forceRefresh()
    }

    private func registerCropUndo(_ items: [(PDFPage, CGRect)], name: String) {
        docUndo.registerUndo(withTarget: self) { me in
            let current = items.map { ($0.0, $0.0.bounds(for: .cropBox)) }
            items.forEach { $0.0.setBounds($0.1, for: .cropBox) }
            me.registerCropUndo(current, name: name)
            me.sidebar.reload()
            me.forceRefresh()
        }
        docUndo.setActionName(name)
    }

    @objc func removeCrop(_ sender: Any?) {
        guard let doc = pdfView.document else { return }
        var items: [(PDFPage, CGRect)] = []
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            let media = p.bounds(for: .mediaBox)
            if p.bounds(for: .cropBox) != media {
                items.append((p, p.bounds(for: .cropBox)))
                p.setBounds(media, for: .cropBox)
            }
        }
        guard !items.isEmpty else { infoAlert("No crop to remove", "No page has a standard crop applied."); return }
        registerCropUndo(items, name: "Remove Crop")
        sidebar.reload()
        forceRefresh()
    }

    private func applyPermanentCrop(rect: CGRect, pages: [Int], in doc: PDFDocument) {
        var swaps: [(Int, PDFPage, PDFPage)] = []   // (index, old, new)
        for i in pages {
            guard let old = doc.page(at: i) else { continue }
            let clipped = rect.intersection(old.bounds(for: .mediaBox))
            guard !clipped.isEmpty, let new = CropEngine.permanentlyCropped(page: old, to: clipped) else { continue }
            doc.removePage(at: i)
            doc.insert(new, at: i)
            swaps.append((i, old, new))
        }
        guard !swaps.isEmpty else { infoAlert("Crop failed", "Couldn't render the cropped page."); return }
        registerPermanentCropUndo(swaps, restoreOld: true, name: "Permanent Crop")
        sidebar.reload()
        forceRefresh()
    }

    // Re-inserting the SAME removed PDFPage object works (identity preserved) — the
    // delete-undo pattern the sidebar already relies on.
    private func registerPermanentCropUndo(_ swaps: [(Int, PDFPage, PDFPage)], restoreOld: Bool, name: String) {
        docUndo.registerUndo(withTarget: self) { me in
            guard let doc = me.pdfView.document else { return }
            for (i, old, new) in swaps {
                doc.removePage(at: i)
                doc.insert(restoreOld ? old : new, at: i)
            }
            me.registerPermanentCropUndo(swaps, restoreOld: !restoreOld, name: name)
            me.sidebar.reload()
            me.forceRefresh()
        }
        docUndo.setActionName(name)
    }

    // MARK: - Compress

    @objc func compressDocument(_ sender: Any?) {
        guard let doc = pdfView.document, let window = window else { return }
        guard let data = doc.dataRepresentation(), let workCopy = PDFDocument(data: data) else {
            infoAlert("Couldn’t prepare document", "The document couldn’t be copied for compression.")
            return
        }
        let originalSize = data.count
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportBaseName + "-compressed.pdf"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let out = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let (ok, n) = CompressEngine.compress(workCopy, to: out)
                let newSize = (try? Data(contentsOf: out).count) ?? 0
                DispatchQueue.main.async {
                    guard ok, newSize > 0 else {
                        infoAlert("Compress failed", "Couldn’t write the compressed PDF.")
                        return
                    }
                    guard newSize < originalSize else {
                        try? FileManager.default.removeItem(at: out)
                        infoAlert("Nothing to gain", "This document is already compact — a compressed copy would not be smaller, so nothing was saved.")
                        return
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                    NSSound(named: "Glass")?.play()
                    let fmt = ByteCountFormatter()
                    let saved = 100 - newSize * 100 / max(1, originalSize)
                    infoAlert("Compressed",
                              "\(fmt.string(fromByteCount: Int64(originalSize))) → \(fmt.string(fromByteCount: Int64(newSize))) (\(saved)% smaller). \(n) scanned page\(n == 1 ? "" : "s") downsampled; pages with text were left untouched.")
                }
            }
        }
    }

    // MARK: - Tools: Make Searchable (OCR), Bates, Watermark

    @objc func makeSearchable(_ sender: Any?) {
        guard let doc = pdfView.document, let window = window else { return }
        // OCR runs off-main; PDFKit isn't thread-safe, so hand the worker its own copy.
        guard let data = doc.dataRepresentation(), let workCopy = PDFDocument(data: data) else {
            infoAlert("Couldn’t prepare document", "The document couldn’t be copied for recognition.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportBaseName + "-searchable.pdf"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let out = panel.url else { return }
            let sheet = ProgressSheetController(title: "Recognizing text on this Mac…", total: workCopy.pageCount)
            window.beginSheet(sheet.window)
            DispatchQueue.global(qos: .userInitiated).async {
                let (ok, n) = OCREngine.makeSearchable(workCopy, to: out) { i, total in
                    DispatchQueue.main.async { sheet.update(done: i + 1, of: total) }
                }
                DispatchQueue.main.async {
                    window.endSheet(sheet.window)
                    if ok {
                        NSWorkspace.shared.activateFileViewerSelecting([out])
                        NSSound(named: "Glass")?.play()
                        infoAlert("Made searchable",
                                  n == 0 ? "Every page already had a text layer — saved an unchanged copy."
                                         : "\(n) scanned page\(n == 1 ? "" : "s") recognized — entirely on this Mac, nothing was uploaded. Saved as \(out.lastPathComponent).")
                    } else {
                        infoAlert("Recognition failed", "Couldn’t write the searchable PDF.")
                    }
                }
            }
        }
    }

    @objc func batesNumbering(_ sender: Any?) {
        guard let doc = pdfView.document, let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "Bates Numbering"
        alert.informativeText = "Stamps a sequential number on every page (as real, searchable text). The original file is untouched."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        let prefix = NSTextField(frame: NSRect(x: 0, y: 32, width: 150, height: 24))
        prefix.placeholderString = "Prefix (e.g. TRC-)"
        let start = NSTextField(frame: NSRect(x: 158, y: 32, width: 74, height: 24))
        start.placeholderString = "Start"; start.stringValue = "1"
        let digits = NSPopUpButton(frame: NSRect(x: 240, y: 30, width: 80, height: 26))
        digits.addItems(withTitles: ["4 digits", "6 digits", "8 digits"])
        digits.selectItem(at: 1)
        let corner = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 232, height: 26))
        corner.addItems(withTitles: ["Bottom Right", "Bottom Left", "Top Right", "Top Left"])
        box.addSubview(prefix); box.addSubview(start); box.addSubview(digits); box.addSubview(corner)
        alert.accessoryView = box
        alert.addButton(withTitle: "Stamp…")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = prefix
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let startN = Int(start.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1
        let digitsN = [4, 6, 8][max(0, digits.indexOfSelectedItem)]
        let cornerV = StampEngine.Corner(rawValue: corner.indexOfSelectedItem) ?? .bottomRight

        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportBaseName + "-bates.pdf"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let out = panel.url else { return }
            if StampEngine.bates(doc, to: out, prefix: prefix.stringValue, start: startN,
                                 digits: digitsN, corner: cornerV) {
                NSWorkspace.shared.activateFileViewerSelecting([out])
                NSSound(named: "Glass")?.play()
            } else {
                infoAlert("Stamp failed", "Couldn’t write the numbered PDF.")
            }
        }
    }

    @objc func addWatermark(_ sender: Any?) {
        guard let doc = pdfView.document, let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "Watermark"
        alert.informativeText = "Stamps a diagonal watermark across every page. The original file is untouched."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        let text = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        text.stringValue = "CONFIDENTIAL"
        let strength = NSPopUpButton(frame: NSRect(x: 208, y: -1, width: 112, height: 26))
        strength.addItems(withTitles: ["Light", "Medium", "Strong"])
        strength.selectItem(at: 1)
        box.addSubview(text); box.addSubview(strength)
        alert.accessoryView = box
        alert.addButton(withTitle: "Stamp…")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = text
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let wmText = text.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wmText.isEmpty else { return }
        let opacity: CGFloat = [0.10, 0.18, 0.28][max(0, strength.indexOfSelectedItem)]

        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportBaseName + "-watermarked.pdf"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let out = panel.url else { return }
            if StampEngine.watermark(doc, to: out, text: wmText, opacity: opacity) {
                NSWorkspace.shared.activateFileViewerSelecting([out])
                NSSound(named: "Glass")?.play()
            } else {
                infoAlert("Watermark failed", "Couldn’t write the watermarked PDF.")
            }
        }
    }

    // MARK: - Lock for Sharing

    @objc func lockForSharing(_ sender: Any?) {
        guard let doc = pdfView.document, let window = window else { return }

        let alert = NSAlert()
        alert.messageText = "Lock for Sharing"
        alert.informativeText = "Saves an AES-256 encrypted copy (the same protection Adobe Acrobat uses). Anyone with the password can open it; the original file is untouched."
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
        panel.nameFieldStringValue = exportBaseName + "-locked.pdf"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let out = panel.url else { return }
            if AES256PDF.encrypt(doc, to: out, userPassword: password, ownerPassword: password) {
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
