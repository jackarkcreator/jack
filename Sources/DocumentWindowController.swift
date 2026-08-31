// The document window: one window per PDF, Preview-style. Native unified toolbar (sidebar,
// zoom, Markup, Lock, Print, search, Save), a Markup tool strip that slides in beneath the
// title bar, and a sidebar that is the page organizer. No secondary windows, no "Home".
import AppKit
import PDFKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                      StampSelectionDelegate, PageSidebarDelegate, NSSearchFieldDelegate,
                                      NSMenuDelegate, NSTextViewDelegate {

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
    // Typewriter: click the page, type, Return — a native FreeText annotation that stays
    // EDITABLE after saving (unlike the old Add Text, which placed a picture of the words).
    private weak var typewriterButton: NSButton?
    private let typewriterSizePopup = NSPopUpButton()
    private let fontPopup = NSPopUpButton()
    private var typewriterEditor: TypewriterEditor?
    private var typewriterTarget: (page: PDFPage, point: CGPoint)?
    private var typewriterEditing: PDFAnnotation?   // set while re-editing an existing text
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
    private let sidebarWidth: CGFloat = 172

    // Mode system (v2.8 ratified mock): one segmented mode — Read · Markup · Redact · Forms —
    // and ONE permanent fixed-height tool row whose CONTENT swaps with the mode. The row never
    // appears or disappears, so switching tools can never shift the page again.
    enum Mode: Int { case read = 0, markup, redact, forms }
    private(set) var mode: Mode = .read
    private var modeSegment: NSSegmentedControl?
    private let modeRow = ToolStripView(frame: NSRect(x: 0, y: 0, width: 1180, height: 42))
    private var redactUsesErase = false      // Erase is a submode of Redact (white vs black paint)
    private var blackoutChip: NSButton?
    private var eraseChip: NSButton?
    private var pagePopup: NSPopUpButton?

    // Floating status HUD (Direction C's contribution to the ratified hybrid): page + zoom,
    // STATUS ONLY — Save keeps its single home in the toolbar. Clicks pass through.
    private let hud = HUDPill()
    private let hudLabel = NSTextField(labelWithString: "")

    // Ask panel (on-device model; only exists when Apple Intelligence is available)
    private var askVisible = false
    private let askWidth: CGFloat = 320
    private let askPanel = NSView()
    private let askQuestion = NSTextField()
    private let askAnswer = NSTextView()
    private let askSpinner = NSProgressIndicator()
    private var askButton: NSButton?
    private var askRunning = false

    // Markup row controls (Size/Remove appear only while a stamp is selected)
    private let sizeSlider = NSSlider()
    private let removeButton = NSButton()
    private let stampSizeLabel = NSTextField(labelWithString: "Size")
    private var markupHint: NSTextField?
    private var shareButton: NSButton?

    // Redact row controls
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

    // Form row controls (field authoring)
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
        DispatchQueue.main.async { [weak self] in self?.setMode(.markup) }
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
        if #available(macOS 13.0, *) { toolbar.centeredItemIdentifiers = [ItemID.modeSegment] }
        installTitleChevron(on: window)

        // The permanent mode row: added once, never removed — only its content swaps.
        // Tahoe hands bottom titlebar accessories their native height (36pt — frame and
        // constraints are both overridden, probed 2026-08-30). The row stays permanent and
        // fixed-height either way; ToolStripView re-centers its controls for whatever
        // height the titlebar grants.
        modeRow.frame = NSRect(x: 0, y: 0, width: window.frame.width, height: 42)
        let rowAcc = NSTitlebarAccessoryViewController()
        rowAcc.view = modeRow
        rowAcc.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(rowAcc)
        populateModeRow()

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
        buildHUD()
        content.addSubview(hud)
        fieldAdornment.isHidden = true
        pdfView.addSubview(fieldAdornment)
        if let clip = pdfView.subviews.compactMap({ ($0 as? NSScrollView)?.contentView }).first {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(pdfViewScrolled),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }
        layoutViews()

        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged),
                                               name: .PDFViewScaleChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                               name: .PDFViewSelectionChanged, object: pdfView)
        pdfView.annotateMenuItems = { [weak self] page, point in
            guard let self else { return [] }
            var items = self.buildAnnotateMenuItems(page: page, point: point)
            // Typewriter text gets browser-style right-click actions.
            if let page, let hit = page.annotations.last(where: {
                $0.type == "FreeText" && $0.bounds.insetBy(dx: -3, dy: -3).contains(point)
            }) {
                let edit = NSMenuItem(title: "Edit Text…", action: #selector(self.editHitFreeText(_:)), keyEquivalent: "")
                edit.target = self
                edit.representedObject = hit
                let remove = NSMenuItem(title: "Remove Text", action: #selector(self.removeHitFreeText(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = hit
                items.insert(.separator(), at: 0)
                items.insert(remove, at: 0)
                items.insert(edit, at: 0)
            }
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
        layoutHUD()
    }

    // MARK: - Floating status HUD (page + zoom, click-through)

    private final class HUDPill: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // status only, never a target
    }

    private func buildHUD() {
        hud.material = .menu
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 14
        hud.layer?.masksToBounds = true
        hud.layer?.borderWidth = 0.5
        hud.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        hudLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        hudLabel.textColor = .secondaryLabelColor
        hudLabel.alignment = .center
        hud.addSubview(hudLabel)
        updateHUD()
    }

    private func layoutHUD() {
        guard let content = window?.contentView else { return }
        let sw = sidebarVisible ? sidebarWidth : 0
        let aw = askVisible ? askWidth : 0
        let w = hudLabel.intrinsicContentSize.width + 32
        // Bottom-centered over the page area (between sidebar and Ask panel), 14pt up — per mock.
        hud.frame = NSRect(x: sw + (content.bounds.width - sw - aw - w) / 2, y: 14, width: w, height: 28)
        hudLabel.frame = NSRect(x: 0, y: (28 - hudLabel.intrinsicContentSize.height) / 2,
                                width: w, height: hudLabel.intrinsicContentSize.height)
    }

    private func updateHUD() {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return }
        let index = doc.index(for: page)
        let pct = Int((pdfView.scaleFactor * 100).rounded())
        hudLabel.stringValue = "Page \(index + 1) of \(doc.pageCount) · \(pct)%"
        layoutHUD()
    }

    @objc private func scaleChanged() { updateHUD(); layoutFieldAdornment() }

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

    // Continuously tracked so forceRefresh can restore position even when the page OBJECT
    // the view was on has just been swapped out (erase/redact/retype replace page objects —
    // a destination captured after the swap points at a page with no index, and without this
    // the restore silently did nothing and the view snapped to the top: "the page jumps").
    private var lastKnownPageIndex = 0

    @objc private func pageChanged() {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return }
        let index = doc.index(for: page)
        if index != NSNotFound { lastKnownPageIndex = index }
        updateHUD()
        syncPagePopup(index: index, count: doc.pageCount)
        sidebar.highlight(pageIndex: index)
    }

    // v2.8: the page indicator lives in the HUD; the subtitle carries only the edit state.
    private func setSubtitle(_ s: String) {
        subtitleBase = s
        let doc = document as? JackDocument
        let dirty = doc?.isDocumentEdited == true
        // While edits are pending on someone else's PDF, say plainly that their file is safe.
        let edited = dirty ? (doc?.protectsOriginal == true ? "Edited · original unchanged" : "Edited") : ""
        if s.isEmpty {
            subtitleLabel.stringValue = edited
        } else {
            subtitleLabel.stringValue = edited.isEmpty ? s : s + " — " + edited
        }
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

    // v2.8 (ratified mock): eight persistent items — everything else lives in its mode, the
    // File/Edit/Tools menus, or the mode row. Undo/redo, Print and Export left the toolbar
    // per the approved diff (⌘Z/⇧⌘Z, ⌘P, ⌘E remain).
    private enum ItemID {
        static let sidebar = NSToolbarItem.Identifier("jack.sidebar")
        static let modeSegment = NSToolbarItem.Identifier("jack.mode")
        static let share = NSToolbarItem.Identifier("jack.share")
        static let ask = NSToolbarItem.Identifier("jack.ask")
        static let saveDoc = NSToolbarItem.Identifier("jack.saveDoc") // Save the document itself
        static let search = NSToolbarItem.Identifier("jack.search")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var ids: [NSToolbarItem.Identifier] =
        [ItemID.sidebar, .flexibleSpace, ItemID.modeSegment, .flexibleSpace,
         ItemID.share, ItemID.search, ItemID.saveDoc]
        if AskEngine.isAvailable, let i = ids.firstIndex(of: ItemID.share) {
            ids.insert(ItemID.ask, at: i)   // wand sits before Share — mock order
        }
        return ids
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    // One symbol pipeline for the whole toolbar: consistent size, weight and scale is most of
    // what separates a current-looking Tahoe toolbar from a dated one. Candidates are tried in
    // order so newer glyph names can ship with safe fallbacks for older systems.
    static let toolbarSymbolConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium, scale: .large)
    static func toolbarSymbol(_ candidates: [String], _ label: String) -> NSImage? {
        for name in candidates {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: label) {
                return img.withSymbolConfiguration(toolbarSymbolConfig) ?? img
            }
        }
        return nil
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func simple(_ id: NSToolbarItem.Identifier, _ symbol: String, _ label: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = Self.toolbarSymbol([symbol], label)
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
            item.image = Self.toolbarSymbol(["sidebar.leading", "sidebar.left"], "View")
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
            let b = NSButton(image: Self.toolbarSymbol(["wand.and.stars"], "Ask") ?? NSImage(),
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
            let b = NSButton(image: Self.toolbarSymbol(["square.and.arrow.up"], "Share") ?? NSImage(),
                             target: self, action: #selector(shareDocument(_:)))
            b.bezelStyle = .texturedRounded
            shareButton = b
            item.view = b
            item.label = "Share"
            item.toolTip = "Share — AirDrop, Mail, Messages…"
            return item
        case ItemID.modeSegment:
            let item = NSToolbarItem(itemIdentifier: id)
            let seg = NSSegmentedControl(labels: modeChoices.map {
                                             switch $0 {
                                             case .read: return "Read"
                                             case .markup: return "Markup"
                                             case .redact: return "Redact"
                                             case .forms: return "Forms"
                                             }
                                         },
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(modeSegmentChanged(_:)))
            seg.selectedSegment = modeChoices.firstIndex(of: mode) ?? 0
            seg.segmentStyle = .automatic
            modeSegment = seg
            item.view = seg
            item.label = "Mode"
            item.toolTip = "Read · Markup (⇧⌘A) · Redact (⇧⌘R) · Forms (⇧⌘F)"
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

    // MARK: - Mode system (v2.8): Read · Markup · Redact · Forms

    /// The modes the segment offers. Forms is product-pulled (2026-08-30) unless the
    /// hidden pref re-enables the kit.
    private var modeChoices: [Mode] { JackFormUI.enabled ? [.read, .markup, .redact, .forms]
                                                         : [.read, .markup, .redact] }

    @objc private func modeSegmentChanged(_ sender: NSSegmentedControl) {
        let choices = modeChoices
        let i = sender.selectedSegment
        setMode(i >= 0 && i < choices.count ? choices[i] : .read)
    }

    // The legacy toggles remain the shortcut/menu entry points (⇧⌘A, ⇧⌘R, ⇧⌘F, View menu).
    @objc func toggleMarkup(_ sender: Any?) { setMode(mode == .markup ? .read : .markup) }
    @objc func toggleForm(_ sender: Any?)   {
        guard JackFormUI.enabled else { return }
        setMode(mode == .forms ? .read : .forms)
    }
    @objc func toggleRedact(_ sender: Any?) {
        if mode == .redact && !redactUsesErase { setMode(.read) }
        else { redactUsesErase = false; setMode(.redact); applyRedactStyle() }
    }
    @objc func toggleErase(_ sender: Any?) {
        if mode == .redact && redactUsesErase { setMode(.read) }
        else { redactUsesErase = true; setMode(.redact); applyRedactStyle() }
    }

    func setMode(_ new: Mode) {
        guard mode != new else { return }
        switch mode {                        // leave the old mode
        case .markup:
            commitTypewriterEditor()         // leaving markup places pending text
            pdfView.typewriterMode = false
            didSelect(nil)
        case .redact:
            pdfView.redactMode = false
            pdfView.eraseStyle = false
        case .forms:
            pdfView.armedFieldKind = nil
            pdfView.formAuthoringOn = false
            fieldPopover?.close()
            commitCaptionEditor()
            pdfView.clearFieldSelection()
        case .read:
            commitFieldTextEditor()
            closeComboPanel()
        }
        mode = new
        switch new {                         // enter the new one
        case .read, .markup: break
        case .redact:
            pdfView.redactMode = true
            pdfView.eraseStyle = redactUsesErase
        case .forms:
            pdfView.formAuthoringOn = true
            pdfView.formFieldMenuItems = { [weak self] widget in self?.fieldMenuItems(for: widget) ?? [] }
        }
        modeSegment?.selectedSegment = modeChoices.firstIndex(of: new) ?? 0
        populateModeRow()
    }

    private func applyRedactStyle() {
        pdfView.eraseStyle = redactUsesErase && mode == .redact
        blackoutChip?.state = redactUsesErase ? .off : .on
        blackoutChip?.bezelColor = redactUsesErase ? nil : .black
        eraseChip?.state = redactUsesErase ? .on : .off
    }

    @objc private func pickBlackout() { redactUsesErase = false; applyRedactStyle() }
    @objc private func pickErase()    { redactUsesErase = true;  applyRedactStyle() }

    /// One row, fixed height, always present — only its content changes (the mock's law).
    private func populateModeRow() {
        modeRow.subviews.forEach { $0.removeFromSuperview() }
        modeRow.resetAnchors()
        pagePopup = nil
        blackoutChip = nil; eraseChip = nil
        markupHint = nil
        switch mode {
        case .read:   buildReadRow()
        case .markup: buildMarkupRow()
        case .redact: buildRedactRow()
        case .forms:  buildFormRow()
        }
    }

    private func rowLabel(_ text: String) {
        let l = NSTextField(labelWithString: text.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        l.frame = NSRect(x: 14, y: 15, width: 56, height: 14)
        modeRow.addSubview(l)
    }

    @discardableResult
    private func rowHint(_ text: String) -> NSTextField {
        let hint = NSTextField(labelWithString: text)
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.alignment = .right
        hint.frame = NSRect(x: 0, y: 13, width: min(640, hint.intrinsicContentSize.width + 8), height: 16)
        modeRow.addSubview(hint)
        modeRow.anchorRight(hint, gap: 16, yields: true)
        return hint
    }

    /// Tool-strip container whose right-aligned controls are re-laid on EVERY resize.
    ///
    /// 🧨 The strips were built with fixed frames at whatever `window.frame.width` happened to
    /// be when the tool was toggled, relying on autoresizing margins from then on. Depending on
    /// how the titlebar imposes the accessory's width (frame vs constraints, maximize vs drag),
    /// the right-edge buttons — including Apply — could end up laid out against a stale width
    /// and drift out of the visible strip on wide or resized windows. Re-anchoring from the
    /// CURRENT bounds on every resize makes the layout correct no matter which path resized us.
    private final class ToolStripView: NSView {
        /// (view, gap): each view's trailing edge sits `gap` points in from the strip's right.
        var rightAligned: [(view: NSView, gap: CGFloat)] = []
        var yielding: Set<ObjectIdentifier> = []          // hints: hide instead of overlapping
        private var yieldOverride: [ObjectIdentifier: Bool] = [:]
        func anchorRight(_ view: NSView, gap: CGFloat, yields: Bool = false) {
            rightAligned.append((view, gap))
            if yields { yielding.insert(ObjectIdentifier(view)) }
            realign()
        }
        func resetAnchors() {
            rightAligned = []; yielding = []; yieldOverride = [:]
        }
        /// External visibility control for a yielding view (collision still wins).
        func setYieldHidden(_ view: NSView, _ hidden: Bool) {
            yieldOverride[ObjectIdentifier(view)] = hidden
            realign()
        }
        private func realign() {
            // Vertically center every control for whatever height the titlebar granted.
            for v in subviews where v.frame.height < bounds.height {
                v.frame.origin.y = ((bounds.height - v.frame.height) / 2).rounded()
            }
            let anchored = Set(rightAligned.map { ObjectIdentifier($0.view) })
            let leftMax = subviews.filter { !anchored.contains(ObjectIdentifier($0)) }
                .map { $0.frame.maxX }.max() ?? 0
            for (v, gap) in rightAligned {
                v.frame.origin.x = bounds.maxX - gap - v.frame.width
                let id = ObjectIdentifier(v)
                if yielding.contains(id) {
                    // A hint never overlaps real controls — it yields (narrow windows).
                    v.isHidden = (yieldOverride[id] ?? false) || v.frame.minX < leftMax + 12
                }
            }
        }
        override func resizeSubviews(withOldSize oldSize: NSSize) {
            super.resizeSubviews(withOldSize: oldSize)
            realign()
        }
        override func layout() {
            super.layout()
            realign()
        }
    }

    private func buildReadRow() {
        rowLabel("Read")
        let zoom = NSSegmentedControl(images: [
            Self.toolbarSymbol(["minus.magnifyingglass"], "Zoom Out") ?? NSImage(),
            Self.toolbarSymbol(["plus.magnifyingglass"], "Zoom In") ?? NSImage()],
            trackingMode: .momentary, target: self, action: #selector(zoomSegment(_:)))
        zoom.controlSize = .small
        zoom.frame = NSRect(x: 74, y: 8, width: 84, height: 26)
        modeRow.addSubview(zoom)

        let pp = NSPopUpButton(frame: NSRect(x: 166, y: 8, width: 108, height: 26), pullsDown: false)
        pp.controlSize = .small
        pp.font = .systemFont(ofSize: 11)
        pp.target = self; pp.action = #selector(pagePicked(_:))
        pagePopup = pp
        modeRow.addSubview(pp)
        if let doc = pdfView.document, let page = pdfView.currentPage {
            syncPagePopup(index: doc.index(for: page), count: doc.pageCount)
        }

        let tools = NSPopUpButton(frame: NSRect(x: 282, y: 8, width: 92, height: 26), pullsDown: true)
        tools.controlSize = .small
        tools.font = .systemFont(ofSize: 11)
        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        titleItem.image = Self.toolbarSymbol(["wrench.and.screwdriver"], "Tools")
        menu.addItem(titleItem)
        func t(_ title: String, _ action: Selector) {
            let m = NSMenuItem(title: title, action: action, keyEquivalent: ""); m.target = self; menu.addItem(m)
        }
        t("Make Searchable (OCR)…", #selector(makeSearchable(_:)))
        t("Bates Numbering…", #selector(batesNumbering(_:)))
        t("Watermark…", #selector(addWatermark(_:)))
        t("Remove Watermark", #selector(removeWatermark(_:)))
        t("Remove Bates Numbering", #selector(removeBates(_:)))
        t("Compress…", #selector(compressDocument(_:)))
        menu.addItem(.separator())
        t("Copy Region as Image", #selector(copyRegionAsImage(_:)))
        t("Save Region as Image…", #selector(saveRegionAsImage(_:)))
        menu.addItem(.separator())
        t("Crop Pages…", #selector(cropPages(_:)))
        t("Remove Crop", #selector(removeCrop(_:)))
        menu.addItem(.separator())
        t("Clean for Sharing…", #selector(cleanForSharing(_:)))
        t("Lock for Sharing…", #selector(lockForSharing(_:)))
        tools.menu = menu
        modeRow.addSubview(tools)

        rowHint("Tools holds: Make Searchable · Bates · Watermark · Compress · Crop · Clean · Lock")
    }

    @objc private func zoomSegment(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { pdfView.zoomOut(sender) } else { pdfView.zoomIn(sender) }
    }

    private func syncPagePopup(index: Int, count: Int) {
        guard let pp = pagePopup else { return }
        if pp.numberOfItems != count {
            pp.removeAllItems()
            pp.addItems(withTitles: (1...max(1, count)).map { "Page \($0)" })
        }
        if index >= 0 && index < pp.numberOfItems { pp.selectItem(at: index) }
    }

    @objc private func pagePicked(_ sender: NSPopUpButton) {
        guard let doc = pdfView.document, let page = doc.page(at: sender.indexOfSelectedItem) else { return }
        pdfView.go(to: page)
    }

    private func chip(_ title: String, _ action: Selector, x: CGFloat, w: CGFloat, toggle: Bool = false) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        if toggle { btn.setButtonType(.pushOnPushOff) }
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.frame = NSRect(x: x, y: 8, width: w, height: 26)
        modeRow.addSubview(btn)
        return btn
    }

    private func buildMarkupRow() {
        rowLabel("Markup")
        let sign = NSPopUpButton(frame: NSRect(x: 74, y: 8, width: 100, height: 26), pullsDown: true)
        sign.controlSize = .small
        sign.font = .systemFont(ofSize: 11)
        let sm = NSMenu()
        let st = NSMenuItem(title: "Sign", action: nil, keyEquivalent: "")
        st.image = Self.toolbarSymbol(["signature"], "Sign")
        sm.addItem(st)
        func si(_ title: String, _ action: Selector) {
            let m = NSMenuItem(title: title, action: action, keyEquivalent: ""); m.target = self; sm.addItem(m)
        }
        si("Add Signature…", #selector(addSignature))
        si("Place Check ✓", #selector(addCheck))
        si("Place Cross ✘", #selector(addCross))
        sign.menu = sm
        modeRow.addSubview(sign)

        let tw = NSButton(title: "Aa Typewriter", target: self, action: #selector(toggleTypewriter))
        tw.setButtonType(.pushOnPushOff)
        tw.bezelStyle = .rounded
        tw.controlSize = .small
        tw.state = pdfView.typewriterMode ? .on : .off
        tw.frame = NSRect(x: 182, y: 8, width: 106, height: 26)
        modeRow.addSubview(tw)
        typewriterButton = tw

        // Font + Size are PERMANENT row controls (they used to pop in over the color dots):
        // idle, they set the default for the next typewriter text; while a capsule is open
        // (typewriter, retype, or editing existing text) they restyle it live.
        if fontPopup.numberOfItems == 0 {
            fontPopup.addItems(withTitles: ["System", "Helvetica", "Arial", "Times New Roman",
                                            "Georgia", "Courier New", "Verdana"])
            let saved = UserDefaults.standard.string(forKey: "jack.textFontFamily") ?? "System"
            if fontPopup.itemTitles.contains(saved) { fontPopup.selectItem(withTitle: saved) }
        }
        fontPopup.frame = NSRect(x: 294, y: 8, width: 126, height: 26)
        fontPopup.controlSize = .small
        fontPopup.font = .systemFont(ofSize: 11)
        fontPopup.target = self; fontPopup.action = #selector(textStylePicked(_:))
        modeRow.addSubview(fontPopup)

        if typewriterSizePopup.numberOfItems == 0 {
            typewriterSizePopup.addItems(withTitles: ["8", "9", "10", "11", "12", "14", "18", "24", "36", "48"])
            let saved = UserDefaults.standard.double(forKey: "jack.textSize")
            typewriterSizePopup.selectItem(withTitle: saved > 0 ? String(Int(saved)) : "14")
            if typewriterSizePopup.indexOfSelectedItem < 0 { typewriterSizePopup.selectItem(withTitle: "14") }
        }
        typewriterSizePopup.frame = NSRect(x: 426, y: 8, width: 56, height: 26)
        typewriterSizePopup.controlSize = .small
        typewriterSizePopup.font = .systemFont(ofSize: 11)
        typewriterSizePopup.target = self; typewriterSizePopup.action = #selector(textStylePicked(_:))
        modeRow.addSubview(typewriterSizePopup)

        var x: CGFloat = 492
        for (i, entry) in Self.highlightColors.enumerated() {
            let dot = NSButton(image: Self.swatch(entry.color), target: self, action: #selector(highlightDotPicked(_:)))
            dot.isBordered = false
            dot.tag = i
            dot.toolTip = "Highlight \(entry.name)"
            dot.frame = NSRect(x: x, y: 12, width: 18, height: 18)
            modeRow.addSubview(dot)
            x += 22
        }
        x += 8
        let u = chip("U", #selector(underlineSelection(_:)), x: x, w: 32)
        u.attributedTitle = NSAttributedString(string: "U", attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        x += 38
        let s = chip("S", #selector(strikethroughSelection(_:)), x: x, w: 32)
        s.attributedTitle = NSAttributedString(string: "S", attributes: [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        x += 38
        let c = chip("Comment", #selector(addComment(_:)), x: x, w: 96)
        c.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Comment")
        c.imagePosition = .imageLeading

        // Size/Remove for the selected stamp live at the right edge; the hint yields to them.
        stampSizeLabel.font = .systemFont(ofSize: 11)
        stampSizeLabel.textColor = .secondaryLabelColor
        stampSizeLabel.frame = NSRect(x: 0, y: 13, width: 30, height: 16)
        modeRow.addSubview(stampSizeLabel)
        sizeSlider.controlSize = .small
        sizeSlider.minValue = 14; sizeSlider.maxValue = 600
        sizeSlider.target = self; sizeSlider.action = #selector(resizeSelected)
        sizeSlider.frame = NSRect(x: 0, y: 10, width: 120, height: 22)
        modeRow.addSubview(sizeSlider)
        removeButton.title = "Remove"
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.target = self; removeButton.action = #selector(removeSelected)
        removeButton.frame = NSRect(x: 0, y: 8, width: 76, height: 26)
        modeRow.addSubview(removeButton)
        modeRow.anchorRight(removeButton, gap: 16)
        modeRow.anchorRight(sizeSlider, gap: 100)
        modeRow.anchorRight(stampSizeLabel, gap: 226)
        markupHint = rowHint("drop an image to place it")
        syncStampControls()
    }

    @objc private func highlightDotPicked(_ sender: NSButton) {
        let i = (0..<Self.highlightColors.count).contains(sender.tag) ? sender.tag : 0
        UserDefaults.standard.set(i, forKey: "jack.highlightColor")
        annotateSelection(.highlight, color: Self.highlightColors[i].color, name: "Highlight")
    }

    private func syncStampControls() {
        let has = selected != nil
        sizeSlider.isHidden = !has;   sizeSlider.isEnabled = has
        removeButton.isHidden = !has; removeButton.isEnabled = has
        stampSizeLabel.isHidden = !has
        if let hint = markupHint { modeRow.setYieldHidden(hint, has) }
    }

    private func buildRedactRow() {
        rowLabel("Redact")
        let black = chip("Blackout", #selector(pickBlackout), x: 74, w: 80, toggle: true)
        let er = chip("Erase", #selector(pickErase), x: 160, w: 64, toggle: true)
        blackoutChip = black
        eraseChip = er
        redactTermField.placeholderString = "Redact every occurrence of…"
        redactTermField.font = .systemFont(ofSize: 12)
        redactTermField.frame = NSRect(x: 234, y: 9, width: 220, height: 24)
        redactTermField.target = self
        redactTermField.action = #selector(redactAllMatches)
        modeRow.addSubview(redactTermField)
        applyRedactStyle()
        rowHint("swipe applies instantly · certificate at save · ⌘Z undoes")
    }

    private func buildFormRow() {
        rowLabel("Forms")
        formPaletteButtons = []
        var x: CGFloat = 74
        for (i, entry) in Self.formPalette.enumerated() {
            let btn = NSButton(title: entry.0, target: self, action: #selector(fieldToolPicked(_:)))
            btn.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: entry.0)
            btn.imagePosition = .imageLeading
            btn.setButtonType(.pushOnPushOff)
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            btn.tag = i
            let w = btn.intrinsicContentSize.width + 14
            btn.frame = NSRect(x: x, y: 8, width: w, height: 26)
            modeRow.addSubview(btn)
            formPaletteButtons.append(btn)
            x += w + 6
        }
        rowHint("click selects · drag moves · corner resizes · double-click caption renames · ⌫ deletes · fill in Read")
    }

    // Erase is an EDIT, not an export: affected pages are swapped in place (undoable via
    // page identity), autosave persists into the file, Versions is the deep recovery.
    // Instant erase — Keno: "why two steps when it can swoosh away magically."
    //
    // Each swipe applies immediately: build the replacement page, verify the target region is
    // gone AND the rest of the page survived, swap, then dissolve the band over the result.
    //
    // 🧨 Repeated swipes must NOT re-rasterize the already-rasterized page — every pass through
    // JPEG costs quality, and a page swiped five times would visibly rot. Each page keeps a
    // SESSION (original page + every region so far, keyed by the current derived page object):
    // a new swipe re-derives from the ORIGINAL with all regions, so the output is always one
    // compression generation from the source no matter how many swipes land on it. Undo swaps
    // back to the previous derived page, and the session map keeps entries for both, so
    // undo/redo and further swipes all stay consistent.
    private var paintSessions: [ObjectIdentifier: (original: PDFPage, paints: [(rect: CGRect, style: RedactionEngine.Style)])] = [:]

    func regionSwiped(_ rect: CGRect, on page: PDFPage, band: NSView, erase: Bool) {
        guard let doc = pdfView.document else { band.removeFromSuperview(); return }
        let index = doc.index(for: page)
        guard index != NSNotFound, rect.width >= 2, rect.height >= 2 else {
            band.removeFromSuperview(); return
        }
        let style: RedactionEngine.Style = erase ? .erase : .blackout
        let session = paintSessions[ObjectIdentifier(page)] ?? (original: page, paints: [])
        let paints = session.paints + [(rect, style)]

        guard let new = RedactionEngine.destroyedPage(session.original, paints: paints),
              (new.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              RedactionEngine.preservesContent(original: session.original, replacement: new,
                                               regions: paints.map { $0.rect }) else {
            band.removeFromSuperview()
            infoAlert(erase ? "Couldn\u{2019}t erase here" : "Couldn\u{2019}t redact here",
                      "This area couldn\u{2019}t be removed cleanly — nothing was changed.")
            return
        }

        // Dissolve the CONTENT, not just the band (Keno): render the region from the PAGE
        // (cacheDisplay on a PDFView returns blank tiles — probed), swap the erased page in
        // beneath it, then break the old ink into dust, invisible-ink style. Blackout keeps
        // its hard bar landing — decisive is the legal convention.
        var dissolve: (image: NSImage, rect: NSRect)?
        if erase, let img = CropEngine.snapshotImage(page: page, region: rect) {
            dissolve = (img, pdfView.convert(rect, from: page))
        }
        withPreservedPosition(anchorIndex: index) {
            doc.removePage(at: index)
            doc.insert(new, at: index)
        }
        paintSessions[ObjectIdentifier(new)] = (session.original, paints)
        docUndo.beginUndoGrouping()
        registerPermanentCropUndo([(index, page, new)], restoreOld: true, name: erase ? "Erase" : "Redact")
        if !erase {
            // The save-time certificate must describe exactly what the document carries —
            // and stop claiming it if the swipe is undone.
            registerRedactionLogUndo(pages: [index], regions: 1, adding: true)
            redactedPageLog.insert(index)
            redactedRegionCount += 1
        }
        docUndo.endUndoGrouping()
        sidebar.reload()
        markDirty()

        // The page underneath is already painted — fading the band is the reveal, not an
        // effect painted over the truth.
        if let d = dissolve {
            band.removeFromSuperview()
            // The refresh cover was added during the swap and sits on top — the dissolve
            // dust must play ABOVE it or its first 300ms are invisible.
            dissolveEffect(image: d.image, over: d.rect)
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                band.animator().alphaValue = 0
            }, completionHandler: { band.removeFromSuperview() })
        }
        flashSubtitle(erase ? "Erased — \u{2318}Z brings it back, drop an image to fill the space"
                            : "Redacted — a verification certificate saves alongside on \u{2318}S. \u{2318}Z undoes")
    }


    // MARK: - Erase dissolve (invisible-ink style: the ink breaks into dust and drifts off)

    private static let dustImage: CGImage? = {
        let s = 8
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        NSColor(white: 0.3, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: s - 2, height: s - 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }()

    /// The erased region's old pixels sit in an overlay while the cleaned page is already
    /// underneath; the overlay fades as a burst of ink-dust drifts off it. Pure reveal —
    /// by the time the dust settles the truth was there all along.
    private func dissolveEffect(image: NSImage, over viewRect: NSRect) {
        let container = NSView(frame: viewRect)
        container.wantsLayer = true
        let iv = NSImageView(frame: container.bounds)
        iv.image = image
        iv.imageScaling = .scaleAxesIndependently
        container.addSubview(iv)
        pdfView.addSubview(container)

        if let dust = Self.dustImage, let layer = container.layer {
            let emitter = CAEmitterLayer()
            emitter.frame = container.bounds
            emitter.emitterShape = .rectangle
            emitter.emitterPosition = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
            emitter.emitterSize = container.bounds.size
            let cell = CAEmitterCell()
            cell.contents = dust
            cell.birthRate = Float(max(80, min(1000, viewRect.width * viewRect.height / 24)))
            cell.lifetime = 0.7
            cell.lifetimeRange = 0.25
            cell.velocity = 16
            cell.velocityRange = 14
            cell.emissionRange = .pi * 2
            cell.yAcceleration = 42       // macOS layer space: +y is up — the dust drifts away
            cell.scale = 0.5
            cell.scaleRange = 0.3
            cell.scaleSpeed = -0.4
            cell.alphaSpeed = -1.6
            emitter.emitterCells = [cell]
            layer.addSublayer(emitter)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { emitter.birthRate = 0 }   // burst, not stream
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            iv.animator().alphaValue = 0
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { container.removeFromSuperview() }
    }

    // MARK: - Form field palette (rendered into the Forms mode row)

    private static let formPalette: [(String, String)] = [
        ("Text Field", "character.cursor.ibeam"), ("Text Box", "text.justify.left"),
        ("Checkbox", "checkmark.square"), ("Multiple Choice", "circle.circle"),
        ("Dropdown", "chevron.down.square"), ("Date", "calendar")]

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
        // One-shot, same rhythm as the typewriter: placing a field disarms the palette.
        pdfView.armedFieldKind = nil
        formPaletteButtons.forEach { $0.state = .off }
        switch kind {
        case .radioGroup, .dropdown:
            openFieldEditor(named: name)   // options matter — offer the editor right away
        default: break
        }
    }

    // Double-clicking a field or its label opens the editor — right-click still works,
    // but nobody should have to find a context menu to rename a field.
    func formFieldEditRequested(name: String) { openFieldEditor(named: name) }

    func fieldResized(_ widget: PDFAnnotation, from oldBounds: CGRect) {
        var items: [(PDFAnnotation, CGRect)] = [(widget, oldBounds)]
        if let page = widget.page, let name = widget.fieldName {
            // Side captions (checkbox/radio) follow the right edge and stay centered.
            for a in page.annotations where FormFieldEngine.isLabel(a, for: name) {
                guard a.bounds.minX >= oldBounds.maxX - 2 else { continue }
                let old = a.bounds
                a.bounds = CGRect(x: widget.bounds.maxX + 6,
                                  y: widget.bounds.midY - old.height / 2,
                                  width: old.width, height: old.height)
                items.append((a, old))
            }
        }
        registerFieldMoveUndo(items, name: "Resize Field")
        selectedStartSize = widget.bounds.size
        fieldAdornment.chipText = nil
        forceRefresh()
        layoutFieldAdornment()
        markDirty()
    }

    // MARK: - Form Kit (approved mock): adornment, fill editors, combo panel, rename, delete

    /// Ring + 4 handles + size chip, drawn in VIEW space so no page-cache repaint is
    /// needed per click; tracks scroll/zoom via notifications.
    private final class FieldAdornment: NSView {
        var chipText: String?
        static let pad: CGFloat = 10
        static let chipBand: CGFloat = 30
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            let pad = Self.pad
            var fieldRect = CGRect(x: pad, y: pad, width: bounds.width - pad * 2, height: bounds.height - pad * 2)
            if chipText != nil { fieldRect.size.height -= Self.chipBand }
            guard fieldRect.width > 4, fieldRect.height > 4, let ctx = NSGraphicsContext.current?.cgContext else { return }
            let ring = fieldRect.insetBy(dx: -4, dy: -4)
            ctx.addPath(CGPath(roundedRect: ring, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.setStrokeColor(JackFormUI.accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
            let h: CGFloat = 8
            for c in [CGPoint(x: ring.minX, y: ring.maxY), CGPoint(x: ring.maxX, y: ring.maxY),
                      CGPoint(x: ring.minX, y: ring.minY), CGPoint(x: ring.maxX, y: ring.minY)] {
                let r = CGRect(x: c.x - h / 2, y: c.y - h / 2, width: h, height: h)
                let path = CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)
                ctx.addPath(path); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
                ctx.addPath(path); ctx.setStrokeColor(JackFormUI.accent.cgColor); ctx.setLineWidth(1.5); ctx.strokePath()
            }
            if let chip = chipText {
                let attr = NSAttributedString(string: chip, attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.white])
                let line = CTLineCreateWithAttributedString(attr)
                let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 16
                let rect = CGRect(x: ring.maxX - w, y: ring.maxY + 8, width: w, height: 19)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.setFillColor(JackFormUI.accent.cgColor)
                ctx.fillPath()
                ctx.textPosition = CGPoint(x: rect.minX + 8, y: rect.minY + 5)
                CTLineDraw(line, ctx)
            }
        }
    }

    private let fieldAdornment = FieldAdornment()
    private weak var selectedFieldWidget: PDFAnnotation?
    private var selectedStartSize: CGSize?

    private func layoutFieldAdornment() {
        guard mode == .forms, let widget = selectedFieldWidget, let page = widget.page else {
            fieldAdornment.isHidden = true
            return
        }
        let viewRect = pdfView.convert(widget.bounds, from: page)
        var frame = viewRect.insetBy(dx: -FieldAdornment.pad, dy: -FieldAdornment.pad)
        if fieldAdornment.chipText != nil { frame.size.height += FieldAdornment.chipBand }
        fieldAdornment.frame = frame
        fieldAdornment.isHidden = false
        fieldAdornment.needsDisplay = true
    }

    @objc private func pdfViewScrolled() { layoutFieldAdornment() }

    func fieldSelected(name: String?, widget: PDFAnnotation?) {
        selectedFieldWidget = widget
        selectedStartSize = widget?.bounds.size
        fieldAdornment.chipText = nil
        layoutFieldAdornment()
    }

    func fieldBoundsChanging() {
        if let w = selectedFieldWidget, let s0 = selectedStartSize, w.bounds.size != s0 {
            fieldAdornment.chipText = "\(Int(w.bounds.width.rounded())) × \(Int(w.bounds.height.rounded()))"
        } else {
            fieldAdornment.chipText = nil
        }
        layoutFieldAdornment()
    }

    func fieldValueChanged() {
        markDirty()
        forceRefresh()   // chrome renders in the page path — the Tahoe cache needs the push
    }

    func fieldDeleteRequested(name: String) {
        guard let doc = pdfView.document else { return }
        var removed: [(PDFPage, PDFAnnotation)] = []
        for i in 0..<doc.pageCount {
            guard let pg = doc.page(at: i) else { continue }
            for a in pg.annotations where (a.type == "Widget" && a.fieldName == name)
                || FormFieldEngine.isLabel(a, for: name) {
                removed.append((pg, a))
            }
        }
        guard !removed.isEmpty else { return }
        removed.forEach { $0.0.removeAnnotation($0.1) }
        registerAnnotationAddUndo(removed, name: "Delete Field")
        pdfView.clearFieldSelection()
        forceRefresh()
        markDirty()
    }

    /// One rename path for the popover, the inline caption editor, and anyone else.
    private func renameField(from oldName: String, to rawNew: String) {
        guard let doc = pdfView.document else { return }
        var newName = rawNew.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != oldName else { return }
        if !groupWidgets(named: newName).isEmpty {
            newName = FormFieldEngine.uniqueName(base: newName, in: doc)   // avoid silent merges
        }
        groupWidgets(named: oldName).forEach { $0.1.fieldName = newName }
        for (_, a) in groupAnnotations(named: oldName) where FormFieldEngine.isLabel(a) {
            if a.contents == oldName { a.contents = newName }    // option captions keep their text
            let suffix = (a.userName ?? "").replacingOccurrences(
                of: FormFieldEngine.labelName(for: oldName), with: "")
            a.userName = FormFieldEngine.labelName(for: newName) + suffix
        }
        docUndo.registerUndo(withTarget: self) { _ in }
        docUndo.setActionName("Rename Field")
        markDirty()
    }

    // MARK: Inline caption rename (double-click the caption, type, Return)

    private var captionEditorBox: NSView?
    private weak var captionField: NSTextField?
    private var captionOldName: String?

    func captionRenameRequested(_ label: PDFAnnotation, fieldName: String, on page: PDFPage) {
        commitCaptionEditor()
        let viewRect = pdfView.convert(label.bounds, from: page)
        let box = NSView(frame: viewRect.insetBy(dx: -3, dy: -2))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.white.cgColor
        let underline = CALayer()
        underline.backgroundColor = JackFormUI.accent.cgColor
        underline.frame = CGRect(x: 0, y: 0, width: box.bounds.width, height: 1.5)
        box.layer?.addSublayer(underline)
        let size = (label.font?.pointSize ?? 12) * pdfView.scaleFactor
        let tf = NSTextField(frame: box.bounds.insetBy(dx: 3, dy: 2))
        tf.isBordered = false
        tf.focusRingType = .none
        tf.drawsBackground = false
        tf.font = .systemFont(ofSize: size)
        tf.stringValue = fieldName
        tf.delegate = self
        tf.target = self
        tf.action = #selector(commitCaptionAction)
        box.addSubview(tf)
        pdfView.addSubview(box)
        window?.makeFirstResponder(tf)
        tf.selectText(nil)
        captionEditorBox = box
        captionField = tf
        captionOldName = fieldName
    }

    @objc private func commitCaptionAction() { commitCaptionEditor() }

    private func commitCaptionEditor() {
        guard let box = captionEditorBox else { return }
        let newName = captionField?.stringValue ?? ""
        let oldName = captionOldName
        box.removeFromSuperview()
        captionEditorBox = nil; captionField = nil; captionOldName = nil
        if let oldName { renameField(from: oldName, to: newName) }
        forceRefresh()
    }

    private func cancelCaptionEditor() {
        captionEditorBox?.removeFromSuperview()
        captionEditorBox = nil; captionField = nil; captionOldName = nil
    }

    // MARK: Fill-mode inline text editor (focus ring + caret are Jack's, per the mock)

    private var fieldTextBox: NSView?
    private weak var fieldTextWidget: PDFAnnotation?
    private weak var fieldTextSingle: NSTextField?
    private weak var fieldTextMulti: NSTextView?

    func fieldFillText(_ widget: PDFAnnotation, on page: PDFPage) {
        commitFieldTextEditor()
        let scale = pdfView.scaleFactor
        let viewRect = pdfView.convert(widget.bounds, from: page)
        let box = NSView(frame: viewRect.insetBy(dx: -2, dy: -2))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.white.cgColor
        box.layer?.cornerRadius = 6 * scale
        box.layer?.borderWidth = 2
        box.layer?.borderColor = JackFormUI.accent.cgColor
        box.layer?.masksToBounds = true
        let size = min(widget.font?.pointSize ?? 13, max(9, widget.bounds.height - 12)) * scale
        let font = widget.font.flatMap { NSFont(descriptor: $0.fontDescriptor, size: size) }
            ?? .systemFont(ofSize: size)
        if widget.isMultiline {
            let tv = NSTextView(frame: box.bounds.insetBy(dx: 8, dy: 6))
            tv.font = font
            tv.string = widget.widgetStringValue ?? ""
            tv.drawsBackground = false
            tv.textColor = .black
            tv.delegate = self
            tv.autoresizingMask = [.width, .height]
            box.addSubview(tv)
            fieldTextMulti = tv
        } else {
            let h = font.ascender - font.descender + 4
            let tf = NSTextField(frame: NSRect(x: 8, y: (box.bounds.height - h) / 2,
                                               width: box.bounds.width - 16, height: h))
            tf.isBordered = false
            tf.focusRingType = .none
            tf.drawsBackground = false
            tf.font = font
            tf.textColor = .black
            tf.stringValue = widget.widgetStringValue ?? ""
            tf.delegate = self
            tf.target = self
            tf.action = #selector(commitFieldTextAction)
            box.addSubview(tf)
            fieldTextSingle = tf
        }
        pdfView.addSubview(box)
        window?.makeFirstResponder((fieldTextSingle as NSView?) ?? fieldTextMulti)
        fieldTextBox = box
        fieldTextWidget = widget
    }

    @objc private func commitFieldTextAction() { commitFieldTextEditor() }

    private func commitFieldTextEditor() {
        guard let box = fieldTextBox else { return }
        let text = fieldTextSingle?.stringValue ?? fieldTextMulti?.string ?? ""
        let widget = fieldTextWidget
        box.removeFromSuperview()
        fieldTextBox = nil; fieldTextWidget = nil; fieldTextSingle = nil; fieldTextMulti = nil
        guard let widget else { return }
        widget.widgetStringValue = text
        markDirty()
        forceRefresh()
    }

    private func cancelFieldTextEditor() {
        fieldTextBox?.removeFromSuperview()
        fieldTextBox = nil; fieldTextWidget = nil; fieldTextSingle = nil; fieldTextMulti = nil
    }

    // Esc inside the multiline field editor cancels it.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView === fieldTextMulti, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelFieldTextEditor()
            return true
        }
        return false
    }
    func textDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSTextView) === fieldTextMulti { commitFieldTextEditor() }
    }

    // MARK: Fill-mode dropdown — an anchored panel, not an NSMenu (the mock's call)

    private var comboPanel: NSPanel?
    private weak var comboWidget: PDFAnnotation?
    private var comboMonitor: Any?

    private final class ComboRow: NSButton {
        var highlightOn = false
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                           owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) { setHighlight(true) }
        override func mouseExited(with event: NSEvent) { setHighlight(false) }
        private func setHighlight(_ on: Bool) {
            highlightOn = on
            wantsLayer = true
            layer?.backgroundColor = on ? JackFormUI.accent.cgColor : NSColor.clear.cgColor
            layer?.cornerRadius = 6
            contentTintColor = on ? .white : .black
        }
    }

    func fieldFillCombo(_ widget: PDFAnnotation, on page: PDFPage) {
        closeComboPanel()
        let options = widget.choices ?? []
        guard !options.isEmpty, let win = window else { return }
        let rowH: CGFloat = 26, pad: CGFloat = 5
        let fieldRect = pdfView.convert(widget.bounds, from: page)
        let width = max(fieldRect.width, 160)
        let h = CGFloat(options.count) * rowH + pad * 2
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.99, alpha: 0.98).cgColor
        content.layer?.cornerRadius = 9
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        let current = widget.widgetStringValue
        for (i, opt) in options.enumerated() {
            let row = ComboRow(title: (opt == current ? "✓  " : "    ") + opt, target: self,
                               action: #selector(comboRowPicked(_:)))
            row.isBordered = false
            row.alignment = .left
            row.font = .systemFont(ofSize: 13)
            row.contentTintColor = .black
            row.tag = i
            row.frame = NSRect(x: pad, y: h - pad - CGFloat(i + 1) * rowH, width: width - pad * 2, height: rowH)
            content.addSubview(row)
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: h),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = content
        let winRect = pdfView.convert(fieldRect, to: nil)
        let screen = win.convertToScreen(winRect)
        panel.setFrame(NSRect(x: screen.minX, y: screen.minY - h - 4, width: width, height: h), display: true)
        win.addChildWindow(panel, ordered: .above)
        comboPanel = panel
        comboWidget = widget
        comboMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] ev in
            if ev.window !== self?.comboPanel { self?.closeComboPanel() }
            return ev
        }
    }

    @objc private func comboRowPicked(_ sender: NSButton) {
        if let widget = comboWidget, let options = widget.choices,
           sender.tag >= 0, sender.tag < options.count {
            widget.widgetStringValue = options[sender.tag]
            markDirty()
        }
        closeComboPanel()
        forceRefresh()
    }

    private func closeComboPanel() {
        if let m = comboMonitor { NSEvent.removeMonitor(m); comboMonitor = nil }
        if let p = comboPanel {
            window?.removeChildWindow(p)
            p.orderOut(nil)
            comboPanel = nil
        }
        comboWidget = nil
    }

    // MARK: Date fields — click pops a calendar; the value lands as plain text, so the
    // field stays an ordinary AcroForm text field in every other reader.

    private var datePopover: NSPopover?
    private weak var dateWidget: PDFAnnotation?
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM/dd/yyyy"; return f
    }()

    func dateFieldClicked(_ widget: PDFAnnotation, on page: PDFPage) {
        let picker = NSDatePicker(frame: NSRect(x: 12, y: 36, width: 139, height: 148))
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay]
        picker.datePickerMode = .single
        if let existing = widget.widgetStringValue, let d = Self.dateFmt.date(from: existing) {
            picker.dateValue = d
        } else {
            picker.dateValue = Date()
        }
        picker.target = self
        picker.action = #selector(datePicked(_:))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 163, height: 196))
        container.addSubview(picker)
        let hint = NSTextField(labelWithString: "Click a day to fill the field")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 12, y: 12, width: 150, height: 14)
        container.addSubview(hint)
        let vc = NSViewController()
        vc.view = container
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        dateWidget = widget
        datePopover = pop
        pop.show(relativeTo: pdfView.convert(widget.bounds, from: page), of: pdfView, preferredEdge: .maxY)
    }

    @objc private func datePicked(_ sender: NSDatePicker) {
        guard let widget = dateWidget else { return }
        widget.widgetStringValue = Self.dateFmt.string(from: sender.dateValue)
        (document as? NSDocument)?.updateChangeCount(.changeDone)
        forceRefresh()
        datePopover?.close()
        datePopover = nil
        dateWidget = nil
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
            if newName != oldName { renameField(from: oldName, to: newName) }
            docUndo.registerUndo(withTarget: self) { _ in }   // dirty the document for autosave
            docUndo.setActionName("Edit Field")
        }
        forceRefresh()
        editingFieldName = nil
    }

    // From SigningPDFView after a rubber-band gesture: the mark exists — make it undoable
    // and force the repaint (PDFView's page cache doesn't reliably show annotation adds).





    @objc private func redactAllMatches() {
        let term = redactTermField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, let doc = pdfView.document else { return }
        let found = doc.findString(term, withOptions: [.caseInsensitive])
        guard !found.isEmpty else { infoAlert("No matches", "\u{201C}\(term)\u{201D} wasn\u{2019}t found in the document."); return }

        // Group matches by page index, then apply each page ONCE — all its bars in a single
        // derivation, the whole term as a single undo step.
        var byPage: [Int: [CGRect]] = [:]
        for sel in found {
            for page in sel.pages {
                let i = doc.index(for: page)
                guard i != NSNotFound else { continue }
                let r = sel.bounds(for: page).insetBy(dx: -2, dy: -2)
                if r.width > 0, r.height > 0 { byPage[i, default: []].append(r) }
            }
        }
        var swaps: [(Int, PDFPage, PDFPage)] = []
        var produced: [(Int, PDFPage, (original: PDFPage, paints: [(rect: CGRect, style: RedactionEngine.Style)]))] = []
        for (i, rects) in byPage.sorted(by: { $0.key < $1.key }) {
            guard let page = doc.page(at: i) else { continue }
            let session = paintSessions[ObjectIdentifier(page)] ?? (original: page, paints: [])
            let paints = session.paints + rects.map { ($0, RedactionEngine.Style.blackout) }
            guard let new = RedactionEngine.destroyedPage(session.original, paints: paints),
                  (new.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  RedactionEngine.preservesContent(original: session.original, replacement: new,
                                                   regions: paints.map { $0.rect }) else {
                infoAlert("Redaction NOT applied",
                          "Page \(i + 1) couldn\u{2019}t be verified — the document was not modified.")
                return
            }
            swaps.append((i, page, new))
            produced.append((i, new, (session.original, paints)))
        }
        withPreservedPosition(anchorIndex: swaps.first?.0) {
            for (i, _, new) in swaps { doc.removePage(at: i); doc.insert(new, at: i) }
        }
        for (_, new, session) in produced { paintSessions[ObjectIdentifier(new)] = session }
        let pages = swaps.map { $0.0 }
        let regionCount = byPage.values.reduce(0) { $0 + $1.count }
        docUndo.beginUndoGrouping()
        registerPermanentCropUndo(swaps, restoreOld: true, name: "Redact \u{201C}\(term)\u{201D}")
        registerRedactionLogUndo(pages: pages, regions: regionCount, adding: true)
        docUndo.endUndoGrouping()
        redactedPageLog.formUnion(pages)
        redactedRegionCount += regionCount
        redactedTerms.insert(term)
        redactTermField.stringValue = ""
        sidebar.reload()
        markDirty()
        NSSound(named: "Glass")?.play()
        flashSubtitle("Redacted \(regionCount) occurrence\(regionCount == 1 ? "" : "s") of \u{201C}\(term)\u{201D} across \(pages.count) page\(pages.count == 1 ? "" : "s") — \u{2318}Z undoes")
    }


    // v2.5: Apply Redactions is an EDIT, not an export — the same discipline as Apply Erase.
    // Every replacement page is built and VERIFIED to carry zero extractable text BEFORE the
    // document is touched; a single failure leaves the document completely unmodified. The
    // verification certificate is emitted at SAVE time, so it hashes the file actually shipped
    // rather than an intermediate the user never sees.

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

    @objc private func toggleTypewriter() {
        let on = !(pdfView.typewriterMode)
        pdfView.typewriterMode = on
        typewriterButton?.state = on ? .on : .off
        if on {
            flashSubtitle("Typewriter — click the page and type. Click anywhere else places it, Esc cancels")
        } else {
            commitTypewriterEditor()
        }
    }

    private var typewriterFontSize: CGFloat {
        CGFloat(Double(typewriterSizePopup.titleOfSelectedItem ?? "14") ?? 14)
    }

    /// The row's Font + Size choice as an actual font ("System" = SF).
    private var currentTextFont: NSFont {
        let fam = fontPopup.titleOfSelectedItem ?? "System"
        let size = typewriterFontSize
        if fam == "System" { return .systemFont(ofSize: size) }
        return NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: size)
            ?? NSFont(name: fam, size: size) ?? .systemFont(ofSize: size)
    }

    /// Reflect a matched/edited annotation's face in the row controls (adds the family and
    /// size to the lists when the document uses one we don't carry).
    private func syncTextStyleControls(matching font: NSFont) {
        guard fontPopup.numberOfItems > 0 else { return }
        let family = font.familyName ?? font.fontName
        if !fontPopup.itemTitles.contains(family) { fontPopup.addItem(withTitle: family) }
        fontPopup.selectItem(withTitle: family)
        let sizeTitle = String(Int(font.pointSize.rounded()))
        if !typewriterSizePopup.itemTitles.contains(sizeTitle) { typewriterSizePopup.addItem(withTitle: sizeTitle) }
        typewriterSizePopup.selectItem(withTitle: sizeTitle)
    }

    @objc private func textStylePicked(_ sender: Any?) {
        UserDefaults.standard.set(fontPopup.titleOfSelectedItem ?? "System", forKey: "jack.textFontFamily")
        UserDefaults.standard.set(Double(typewriterFontSize), forKey: "jack.textSize")
        guard let editor = typewriterEditor else { return }
        let f = currentTextFont
        retypeFont = f
        if let scaled = NSFont(descriptor: f.fontDescriptor, size: f.pointSize * pdfView.scaleFactor) {
            editor.field.font = scaled
            editor.sizeToText()
        }
    }

    // MARK: Typewriter editor overlay

    func typewriterClicked(at point: CGPoint, on page: PDFPage) {
        commitTypewriterEditor()   // a still-open capsule commits first
        retypeFont = currentTextFont   // the row's Font/Size choice styles the new text
        openTypewriterEditor(on: page, at: point, existing: nil)
        // One-shot (the armed tool kept spawning boxes on every click): placing the capsule
        // disarms the tool. Click away to place the text; Esc cancels.
        pdfView.typewriterMode = false
        typewriterButton?.state = .off
    }

    func freeTextEditRequested(_ ann: PDFAnnotation) {
        guard let page = ann.page else { return }
        commitTypewriterEditor()
        // Edit in place: the annotation comes off the page while the editor is up, and
        // commit/cancel decides what goes back. Undo treats the whole edit as one step.
        typewriterEditing = ann
        if let f = ann.font {
            retypeFont = f
            if mode == .markup { syncTextStyleControls(matching: f) }
        }
        if let c = ann.fontColor { retypeColor = c }
        page.removeAnnotation(ann)
        forceRefresh()
        openTypewriterEditor(on: page, at: CGPoint(x: ann.bounds.minX, y: ann.bounds.maxY),
                             existing: ann)
    }

    // Set by Retype so the replacement matches the ORIGINAL run — exact face, size and colour
    // read from the selection (PDFKit exposes all three). Cleared on commit/cancel.
    private var retypeFont: NSFont?
    private var retypeColor: NSColor?

    private func openTypewriterEditor(on page: PDFPage, at point: CGPoint, existing: PDFAnnotation?,
                                      prefill: String? = nil, sizeOverride: CGFloat? = nil) {
        let size = sizeOverride ?? retypeFont?.pointSize
            ?? existing.flatMap { $0.font?.pointSize } ?? typewriterFontSize
        let scale = pdfView.scaleFactor
        let viewPoint = pdfView.convert(point, from: page)
        let editor = TypewriterEditor(text: prefill ?? existing?.contents ?? "",
                                      fontSize: size * scale,
                                      at: NSPoint(x: viewPoint.x - 7, y: viewPoint.y - 60))
        // WYSIWYG: type in the face you'll get.
        if let f = retypeFont, let scaled = NSFont(descriptor: f.fontDescriptor, size: size * scale) {
            editor.field.font = scaled
            editor.sizeToText()
        }
        editor.setFrameOrigin(NSPoint(x: viewPoint.x - 7, y: viewPoint.y + 7 - editor.frame.height))
        editor.field.delegate = self
        editor.field.target = self
        editor.field.action = #selector(typewriterCommitAction)
        // Dragging the capsule's ring repositions the pending text; the commit point follows.
        editor.onMoved = { [weak self, weak editor] in
            guard let self, let editor, let target = self.typewriterTarget else { return }
            let topLeft = self.pdfView.convert(editor.textTopLeftInSuperview, to: target.page)
            self.typewriterTarget = (target.page, topLeft)
        }
        pdfView.addSubview(editor)
        pdfView.window?.makeFirstResponder(editor.field)
        typewriterEditor = editor
        typewriterTarget = (page, point)
    }

    // Retype: the fused Erase + Typewriter gesture — select words, and Jack removes exactly
    // that span (verified, background-matched) and opens the editor pre-filled with the same
    // words, sized to the line, right where they were.
    //
    // What Adobe's "Edit PDF" does — rewriting glyph runs in place — silently substitutes
    // fonts and reflows lines whenever the embedded subset lacks a glyph, which is most edits
    // in most branded documents. Jack refuses to fake that. Retype is the honest version, and
    // it says plainly what it does: the page is re-rendered (like Erase), the replacement text
    // is a real annotation that stays editable, and Make Searchable can restore the page's
    // text layer afterwards — at which point the retyped words become searchable too, because
    // OCR reads the page WITH its annotations.
    @objc func retypeSelection(_ sender: Any?) {
        guard let doc = pdfView.document else { return }
        let live = pdfView.currentSelection
        let liveOK = !((live?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        guard let sel = liveOK ? live : lastSelection,
              let page = sel.pages.first else {
            infoAlert("Nothing selected", "Select the words you want to retype first.")
            return
        }
        let text = (sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rect = sel.bounds(for: page)
        guard !text.isEmpty, rect.width > 1, rect.height > 1 else { return }

        if !UserDefaults.standard.bool(forKey: "jack.retypeExplained") {
            let a = NSAlert()
            a.messageText = "Retype these words?"
            a.informativeText = "Jack removes the selected words by re-rendering this page (it becomes an image, like Erase), then places the same words as editable text for you to change.\n\nRun Make Searchable afterwards if you need this page's text searchable again. Nothing is written until you save, and \u{2318}Z undoes it."
            a.addButton(withTitle: "Retype")
            a.addButton(withTitle: "Cancel")
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Don\u{2019}t ask again"
            guard a.runModal() == .alertFirstButtonReturn else { return }
            if a.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: "jack.retypeExplained")
            }
        }

        // Where the original ink actually starts vertically — measured, so the replacement
        // sits ON the old line, not merely inside the selection box.
        let originalInkTop = RetypeMetrics.inkTop(of: page, in: rect)
        // Pad the erase: raster rounding and glyph antialiasing leave sliver artifacts at the
        // exact selection edge. The halo is vertical (above/below the glyph run), so pad
        // generously there — but neighbouring words sit ~1pt away HORIZONTALLY, and 1.25pt of
        // side padding clipped the tail of the word before the selection. 0.4pt kills the
        // rounding sliver without touching the neighbour.
        let eraseRect = rect.insetBy(dx: -0.4, dy: -1.5)
            .intersection(page.bounds(for: .mediaBox))
        let index = doc.index(for: page)
        guard index != NSNotFound,
              let new = RedactionEngine.destroyedPage(page, regions: [eraseRect], style: .erase),
              RedactionEngine.preservesContent(original: page, replacement: new, regions: [eraseRect]) else {
            infoAlert("Couldn\u{2019}t retype here", "This span couldn\u{2019}t be removed cleanly, so nothing was changed.")
            return
        }
        withPreservedPosition(anchorIndex: index) {
            doc.removePage(at: index)
            doc.insert(new, at: index)
        }
        registerPermanentCropUndo([(index, page, new)], restoreOld: true, name: "Retype")
        sidebar.reload()
        lastSelection = nil
        markDirty()

        // Match the ORIGINAL run: PDFKit's selection carries the exact face, size and colour.
        // (A subset-embedded name like "ABCDEF+Arial" needs its prefix stripped to resolve.)
        var fontSize = min(72, max(8, (rect.height * 0.72).rounded()))
        if let attr = sel.attributedString, attr.length > 0 {
            let a = attr.attributes(at: 0, effectiveRange: nil)
            if let f = a[.font] as? NSFont {
                fontSize = f.pointSize
                let bare = f.fontName.contains("+") ? String(f.fontName.split(separator: "+").last!) : f.fontName
                retypeFont = NSFont(name: bare, size: f.pointSize)
                    ?? NSFont(descriptor: f.fontDescriptor, size: f.pointSize)
            }
            if let c = a[.foregroundColor] as? NSColor { retypeColor = c }
        }
        // The editor stands alone — Retype is one gesture, it must NOT leave the typewriter
        // armed. (Armed mode turned the next text-selection click into "place an editor here",
        // which also yanked the view to the new capsule — the "jumps when I select" bug.)
        setMode(.markup)   // retype IS markup — the row's Font/Size controls restyle the capsule
        if let f = retypeFont { syncTextStyleControls(matching: f) }
        openTypewriterEditor(on: new, at: CGPoint(x: rect.minX, y: originalInkTop ?? rect.maxY - 1),
                             existing: nil, prefill: text, sizeOverride: fontSize)
        typewriterEditor?.field.selectText(nil)
        flashSubtitle("Retype — edit the words, Return places them. \u{2318}Z twice undoes everything")
    }

    @objc private func typewriterCommitAction() { commitTypewriterEditor() }

    @objc private func editHitFreeText(_ sender: NSMenuItem) {
        guard let ann = sender.representedObject as? PDFAnnotation else { return }
        freeTextEditRequested(ann)
    }

    @objc private func removeHitFreeText(_ sender: NSMenuItem) {
        guard let ann = sender.representedObject as? PDFAnnotation, let page = ann.page else { return }
        page.removeAnnotation(ann)
        registerFreeTextUndo(page: page, add: nil, remove: ann, name: "Remove Text")
        forceRefresh()
        markDirty()
    }

    /// Places the editor's text as a FreeText annotation (or restores/updates the one being
    /// edited). Safe to call when no editor is open.
    private func commitTypewriterEditor() {
        guard let editor = typewriterEditor, let target = typewriterTarget else { return }
        let text = editor.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let editing = typewriterEditing
        editor.removeFromSuperview()
        typewriterEditor = nil
        typewriterTarget = nil
        typewriterEditing = nil

        if text.isEmpty {
            // Empty commit: a new placement becomes nothing; an edited annotation is removed.
            if let old = editing {
                registerFreeTextUndo(page: target.page, add: nil, remove: old, name: "Remove Text")
                forceRefresh()
                markDirty()
            }
            return
        }

        let size = (editor.field.font?.pointSize ?? 14) / max(0.01, pdfView.scaleFactor)
        let font = retypeFont.flatMap { NSFont(descriptor: $0.fontDescriptor, size: size) }
            ?? NSFont.systemFont(ofSize: size.rounded())
        let color = retypeColor ?? .black
        retypeFont = nil; retypeColor = nil
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let bounds: CGRect
        if let old = editing {
            bounds = CGRect(x: old.bounds.minX, y: old.bounds.maxY - measured.height - 4,
                            width: measured.width + 8, height: measured.height + 4)
        } else {
            bounds = CGRect(x: target.point.x, y: target.point.y - measured.height - 4,
                            width: measured.width + 8, height: measured.height + 4)
        }
        // The point the user (or Retype) gave us is where the INK should start — compensate
        // for FreeText's internal inset so it does, instead of drifting right and down.
        let inset = RetypeMetrics.inkInset(for: font)
        let placed = bounds.offsetBy(dx: -inset.left, dy: inset.top)
        let ann = PDFAnnotation(bounds: placed, forType: .freeText, withProperties: nil)
        ann.contents = text
        ann.font = font
        ann.fontColor = color
        ann.color = .clear
        let border = PDFBorder(); border.lineWidth = 0
        ann.border = border
        target.page.addAnnotation(ann)
        registerFreeTextUndo(page: target.page, add: ann, remove: editing, name: editing == nil ? "Add Text" : "Edit Text")
        forceRefresh()
        markDirty()
    }

    private func cancelTypewriterEditor() {
        retypeFont = nil; retypeColor = nil
        guard let editor = typewriterEditor else { return }
        let editing = typewriterEditing
        let target = typewriterTarget
        editor.removeFromSuperview()
        typewriterEditor = nil
        typewriterTarget = nil
        typewriterEditing = nil
        // Cancel while re-editing: put the original back untouched (no undo entry).
        if let old = editing, let page = target?.page {
            page.addAnnotation(old)
            forceRefresh()
        }
    }

    func freeTextMoved(_ ann: PDFAnnotation, from oldBounds: CGRect) {
        docUndo.registerUndo(withTarget: self) { me in
            let now = ann.bounds
            ann.bounds = oldBounds
            me.freeTextMoved(ann, from: now)
            me.forceRefresh()
        }
        docUndo.setActionName("Move Text")
        // 🧨 Tahoe's render cache ghosts a MOVED native annotation exactly like an added one:
        // the cached page still shows the old position while the annotation draws at the new
        // one — two copies of the same text on screen, none of them a real duplicate. Same
        // lesson as adds/deletes: repaint via document-reassign at gesture end.
        forceRefresh()
        markDirty()
    }

    /// One undoable step covering add and/or remove; inverse re-registers, so redo is free.
    private func registerFreeTextUndo(page: PDFPage, add: PDFAnnotation?, remove: PDFAnnotation?, name: String) {
        docUndo.registerUndo(withTarget: self) { me in
            if let a = add { page.removeAnnotation(a) }
            if let r = remove { page.addAnnotation(r) }
            me.registerFreeTextUndo(page: page, add: remove, remove: add, name: name)
            me.forceRefresh()
        }
        docUndo.setActionName(name)
    }

    private func markDirty() { (document as? NSDocument)?.updateChangeCount(.changeDone) }

    // addText (image-of-words) was replaced by the Typewriter: real FreeText,
    // editable after saving. addCheck/addCross still use renderText below.

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
            if mode != .markup { setMode(.markup) }   // clicking a stamp surfaces its controls
        }
        syncStampControls()
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

    /// THE position law: every mutation of the displayed document goes through here.
    ///
    /// Capture the reading position BEFORE the mutation (PDFView reacts to removePage/insert
    /// on its live document, so capturing afterwards reads an already-disturbed view), run the
    /// mutation, bust Tahoe's render cache by reassigning the document, restore — and then
    /// RE-ASSERT the restore on the next two runloop turns, because PDFKit queues relayouts
    /// (auto-fit, notification handlers) that can move the view after our synchronous restore
    /// returns. `anchorIndex` is the page the user actually edited: if the captured
    /// destination is unusable, the view stays on that page — never "some other page".
    private func withPreservedPosition(anchorIndex: Int? = nil, _ mutate: () -> Void) {
        let scale = pdfView.scaleFactor
        let autoScales = pdfView.autoScales
        var destIndex: Int?
        var destPoint = CGPoint.zero
        if let dest = pdfView.currentDestination, let p = dest.page, let d = pdfView.document {
            let i = d.index(for: p)
            destIndex = i != NSNotFound ? i : (anchorIndex ?? lastKnownPageIndex)
            destPoint = dest.point
        } else {
            destIndex = anchorIndex ?? lastKnownPageIndex
        }

        mutate()

        let doc = pdfView.document
        // The reassign rebuilds PDFView's tiles ASYNCHRONOUSLY — the view blanks (white)
        // until they land, a visible flash on dark pages. Cover the visible page area with
        // its real post-mutation pixels (page render — the proven path) while tiles settle.
        let cover = makeRefreshCover(doc: doc, destIndex: destIndex)
        pdfView.document = nil
        pdfView.document = doc
        let restore: () -> Void = { [weak self] in
            guard let self, let doc = self.pdfView.document else { return }
            if autoScales { self.pdfView.autoScales = true } else { self.pdfView.scaleFactor = scale }
            if let i = destIndex, let page = doc.page(at: min(i, max(0, doc.pageCount - 1))) {
                self.pdfView.go(to: PDFDestination(page: page, at: destPoint))
            }
        }
        restore()
        DispatchQueue.main.async(execute: restore)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: restore)
        if let cover {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.12
                    cover.animator().alphaValue = 0
                }, completionHandler: { cover.removeFromSuperview() })
            }
        }
        pageChanged()
    }

    private func forceRefresh() { withPreservedPosition {} }

    /// Full-view cover shown while the document reassign rebuilds PDFView's tiles (async —
    /// the view blanks until they land). Three laws learned the hard way:
    /// • The margin color must resolve against the view's EFFECTIVE appearance — a dynamic
    ///   NSColor→cgColor outside a draw pass resolves Aqua, which painted dark-mode margins
    ///   light grey: the "white/grey overlay" Keno saw on every markup apply.
    /// • EVERY visible page gets real pixels, not just the anchor — a page boundary on
    ///   screen otherwise flashes bare background where the neighbor page sits.
    /// • Page GEOMETRY comes from the view's (possibly just-swapped-out) page objects, but
    ///   CONTENT renders from the document's current page at that index — the cover must
    ///   show the post-mutation truth.
    private func makeRefreshCover(doc: PDFDocument?, destIndex: Int?) -> NSView? {
        guard let doc, doc.pageCount > 0 else { return nil }
        let container = NSView(frame: pdfView.bounds)
        container.wantsLayer = true
        var bg = NSColor.windowBackgroundColor.cgColor
        pdfView.effectiveAppearance.performAsCurrentDrawingAppearance {
            bg = NSColor.underPageBackgroundColor.cgColor
        }
        container.layer?.backgroundColor = bg
        // visiblePages can come back empty (offscreen, mid-layout) — the anchor page is
        // always a valid stand-in; a cover that silently vanishes brings the flash back.
        var pages = pdfView.visiblePages
        if pages.isEmpty, let anchor = pdfView.currentPage ?? doc.page(at: min(max(0, destIndex ?? 0), doc.pageCount - 1)) {
            pages = [anchor]
        }
        var covered = 0
        for viewPage in pages {
            var idx = doc.index(for: viewPage)
            if idx == NSNotFound {   // the mutation swapped this page object out
                idx = min(max(0, destIndex ?? lastKnownPageIndex), doc.pageCount - 1)
            }
            guard let fresh = doc.page(at: idx) else { continue }
            let pageVisible = pdfView.convert(pdfView.bounds, to: viewPage)
                .intersection(viewPage.bounds(for: .cropBox))
            guard pageVisible.width > 4, pageVisible.height > 4,
                  let img = CropEngine.snapshotImage(page: fresh, region: pageVisible) else { continue }
            let iv = NSImageView(frame: pdfView.convert(pageVisible, from: viewPage))
            iv.image = img
            iv.imageScaling = .scaleAxesIndependently
            container.addSubview(iv)
            covered += 1
        }
        if covered == 0 {
            // Geometry can be unknowable (mid-layout, offscreen restore): render the whole
            // anchor page rather than let the flash through naked. A best-effort placement
            // for 300ms beats a white blink every time.
            let idx = min(max(0, destIndex ?? lastKnownPageIndex), doc.pageCount - 1)
            if let page = pdfView.currentPage ?? doc.page(at: idx),
               let img = CropEngine.snapshotImage(page: page, region: page.bounds(for: .cropBox)) {
                var frame = pdfView.convert(page.bounds(for: .cropBox), from: page)
                if !frame.intersects(container.bounds) || frame.isEmpty || frame.isInfinite {
                    frame = container.bounds.insetBy(dx: 20, dy: 20)
                }
                let iv = NSImageView(frame: frame)
                iv.image = img
                iv.imageScaling = .scaleProportionallyUpOrDown
                container.addSubview(iv)
                covered = 1
            }
        }
        guard covered > 0 else { return nil }
        pdfView.addSubview(container)
        return container
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
            let retype = NSMenuItem(title: "Retype\u{2026}", action: #selector(retypeSelection(_:)), keyEquivalent: "")
            retype.target = self
            items.append(retype)
            items.append(.separator())
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

        withPreservedPosition(anchorIndex: index) {
            doc.removePage(at: index)
            doc.insert(cleaned, at: index)
        }
        registerPermanentCropUndo([(index, page, cleaned)], restoreOld: true, name: "Remove Object")
        lastImageHit = nil
        sidebar.reload()
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
            me.withPreservedPosition(anchorIndex: swaps.first?.0) {
                for (i, old, new) in swaps {
                    doc.removePage(at: i)
                    doc.insert(restoreOld ? old : new, at: i)
                }
            }
            me.registerPermanentCropUndo(swaps, restoreOld: !restoreOld, name: name)
            me.sidebar.reload()
        }
        docUndo.setActionName(name)
    }

    // MARK: - Compress

    // v2.5: Compress edits the open document. Only the pages the engine actually re-rendered
    // are swapped in — pages it passed through keep their live annotations and form fields.
    @objc func compressDocument(_ sender: Any?) {
        guard let doc = pdfView.document else { return }
        // The engine runs off-main; PDFKit is not thread-safe, so hand it its own copy.
        guard let data = doc.dataRepresentation(), let workCopy = PDFDocument(data: data) else {
            infoAlert("Couldn\u{2019}t prepare document", "The document couldn\u{2019}t be copied for compression.")
            return
        }
        let originalSize = data.count
        let out = tempWorkURL("compress")
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, changed) = CompressEngine.compress(workCopy, to: out)
            let producedSize = (try? Data(contentsOf: out).count) ?? 0
            DispatchQueue.main.async { [weak self] in
                defer { try? FileManager.default.removeItem(at: out) }
                guard let self = self else { return }
                guard ok, producedSize > 0 else {
                    infoAlert("Compress failed", "Couldn\u{2019}t compress this document. Nothing was changed.")
                    return
                }
                guard producedSize < originalSize, !changed.isEmpty else {
                    infoAlert("Nothing to gain",
                              "This document is already compact — compressing it would not make it smaller, so nothing was changed.")
                    return
                }
                guard self.swapTransformedPages(from: out, changed: changed, name: "Compress") else {
                    infoAlert("Compress failed",
                              "The compressed pages couldn\u{2019}t be applied — the document was not modified.")
                    return
                }
                NSSound(named: "Glass")?.play()
                // Report the REAL resulting size, measured after the swap, not the engine's
                // intermediate — only the changed pages were taken from it.
                let finalSize = self.pdfView.document?.dataRepresentation()?.count ?? producedSize
                let fmt = ByteCountFormatter()
                let saved = 100 - finalSize * 100 / max(1, originalSize)
                let n = changed.count
                infoAlert("Compressed",
                          "\(fmt.string(fromByteCount: Int64(originalSize))) \u{2192} \(fmt.string(fromByteCount: Int64(finalSize))) "
                          + "(\(saved)% smaller). \(n) scanned page\(n == 1 ? "" : "s") downsampled; pages with text were left untouched."
                          + "\n\n\u{2318}S to save, \u{2318}Z to undo.")
            }
        }
    }

    /// Swap ONLY the pages an engine transformed into the live document, with page-identity
    /// undo. Pages the engine passed through are never touched, so their highlights, comments
    /// and form fields survive an in-place tool. Returns false without modifying anything.
    private func swapTransformedPages(from producedURL: URL, changed: [Int], name: String) -> Bool {
        guard let doc = pdfView.document,
              let produced = PDFDocument(url: producedURL),
              produced.pageCount == doc.pageCount else { return false }
        var swaps: [(Int, PDFPage, PDFPage)] = []
        for i in changed {
            guard let old = doc.page(at: i), let new = produced.page(at: i) else { return false }
            new.retainBackingDocument(produced)   // else it copies as blank when saved
            swaps.append((i, old, new))
        }
        guard !swaps.isEmpty else { return true }
        withPreservedPosition(anchorIndex: swaps.first?.0) {
            for (i, _, new) in swaps {
                doc.removePage(at: i)
                doc.insert(new, at: i)
            }
        }
        registerPermanentCropUndo(swaps, restoreOld: true, name: name)
        sidebar.reload()
        return true
    }

    private func tempWorkURL(_ prefix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jack-tools", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(prefix)-\(UUID().uuidString).pdf")
    }

    // MARK: - Tools: Make Searchable (OCR), Bates, Watermark

    // v2.5: Make Searchable edits the open document — only the pages that actually had no
    // text layer are swapped in, so annotated and fillable pages are left alone.
    @objc func makeSearchable(_ sender: Any?) {
        guard let doc = pdfView.document, let window = window else { return }
        // OCR runs off-main; PDFKit isn't thread-safe, so hand the worker its own copy.
        guard let data = doc.dataRepresentation(), let workCopy = PDFDocument(data: data) else {
            infoAlert("Couldn\u{2019}t prepare document", "The document couldn\u{2019}t be copied for recognition.")
            return
        }
        let out = tempWorkURL("ocr")
        let sheet = ProgressSheetController(title: "Recognizing text on this Mac\u{2026}", total: workCopy.pageCount)
        window.beginSheet(sheet.window)
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, changed) = OCREngine.makeSearchable(workCopy, to: out) { i, total in
                DispatchQueue.main.async { sheet.update(done: i + 1, of: total) }
            }
            DispatchQueue.main.async { [weak self] in
                defer { try? FileManager.default.removeItem(at: out) }
                window.endSheet(sheet.window)
                guard let self = self else { return }
                guard ok else {
                    infoAlert("Recognition failed", "Couldn\u{2019}t recognize this document. Nothing was changed.")
                    return
                }
                guard !changed.isEmpty else {
                    infoAlert("Already searchable",
                              "Every page already carries a text layer — nothing needed recognizing, so nothing was changed.")
                    return
                }
                guard self.swapTransformedPages(from: out, changed: changed, name: "Make Searchable") else {
                    infoAlert("Recognition failed",
                              "The recognized pages couldn\u{2019}t be applied — the document was not modified.")
                    return
                }
                NSSound(named: "Glass")?.play()
                let n = changed.count
                infoAlert("Made searchable",
                          "\(n) scanned page\(n == 1 ? "" : "s") recognized — entirely on this Mac, nothing was uploaded. "
                          + "You can now search and select the text."
                          + "\n\n\u{2318}S to save, \u{2318}Z to undo.")
            }
        }
    }

    // v2.5 Phase 3: Bates and Watermark are LIVE marks on the open document — visible at once,
    // undoable, removable — and they burn into the page as REAL VECTOR CONTENT at save, so a
    // Bates number stays extractable and searchable the way legal production requires.
    @objc func batesNumbering(_ sender: Any?) {
        guard let doc = pdfView.document else { return }
        let alert = NSAlert()
        alert.messageText = "Bates Numbering"
        alert.informativeText = "Numbers every page sequentially. The numbers appear now and are written into the file when you save."
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
        alert.addButton(withTitle: "Add Numbering")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = prefix
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard confirmFlattenIfForm("Bates numbering") else { return }

        let startN = Int(start.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1
        let digitsN = [4, 6, 8][max(0, digits.indexOfSelectedItem)]
        let cornerV = StampEngine.Corner(rawValue: corner.indexOfSelectedItem) ?? .bottomRight

        applyOverlay(name: "Bates Numbering", replacing: { $0 is BatesAnnotation }) { page in
            BatesAnnotation(prefix: prefix.stringValue, start: startN, digits: digitsN,
                            corner: cornerV, pageBox: page.bounds(for: .mediaBox))
        }
        flashSubtitle("Bates numbering added — renumbers if you reorder pages. \u{2318}S to save, \u{2318}Z to undo")
    }

    @objc func addWatermark(_ sender: Any?) {
        guard pdfView.document != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Watermark"
        alert.informativeText = "Stamps a diagonal watermark across every page. It appears now and is written into the file when you save."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        let text = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        text.stringValue = "CONFIDENTIAL"
        let strength = NSPopUpButton(frame: NSRect(x: 208, y: -1, width: 112, height: 26))
        strength.addItems(withTitles: ["Light", "Medium", "Strong"])
        strength.selectItem(at: 1)
        box.addSubview(text); box.addSubview(strength)
        alert.accessoryView = box
        alert.addButton(withTitle: "Add Watermark")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = text
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let wmText = text.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wmText.isEmpty else { return }
        guard confirmFlattenIfForm("A watermark") else { return }
        let opacity: CGFloat = [0.10, 0.18, 0.28][max(0, strength.indexOfSelectedItem)]

        applyOverlay(name: "Watermark", replacing: { $0 is WatermarkAnnotation }) { page in
            WatermarkAnnotation(text: wmText, opacity: opacity, pageBox: page.bounds(for: .mediaBox))
        }
        flashSubtitle("Watermark added — \u{2318}S to save, \u{2318}Z to undo")
    }

    @objc func removeWatermark(_ sender: Any?) { removeOverlays(name: "Remove Watermark") { $0 is WatermarkAnnotation } }
    @objc func removeBates(_ sender: Any?) { removeOverlays(name: "Remove Bates Numbering") { $0 is BatesAnnotation } }

    // MARK: - Overlay plumbing

    /// Burning a mark into a page rebuilds it, and a rebuilt page cannot keep live form
    /// widgets. Say so plainly and let the user decide rather than silently killing their form.
    private func confirmFlattenIfForm(_ what: String) -> Bool {
        guard let doc = pdfView.document, FormFieldEngine.hasWidgets(doc) else { return true }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "This document has fillable form fields"
        a.informativeText = "\(what) is written into the page itself when you save, which finalizes the form fields on these pages — they will keep their current values but stop being fillable.\n\nNothing is written until you save, and \u{2318}Z undoes this."
        a.addButton(withTitle: "Add Anyway")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Add one mark per page, replacing any of the same kind, as ONE undoable step.
    private func applyOverlay(name: String, replacing matches: @escaping (PDFAnnotation) -> Bool,
                              make: (PDFPage) -> OverlayAnnotation) {
        guard let doc = pdfView.document else { return }
        var removed: [(PDFPage, PDFAnnotation)] = []
        var added: [(PDFPage, PDFAnnotation)] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for old in page.annotations where matches(old) {
                page.removeAnnotation(old)
                removed.append((page, old))
            }
            let mark = make(page)
            page.addAnnotation(mark)
            added.append((page, mark))
        }
        docUndo.beginUndoGrouping()
        registerOverlayUndo(added: added, removed: removed, name: name)
        docUndo.endUndoGrouping()
        forceRefresh()
        sidebar.reload()
        NSSound(named: "Glass")?.play()
    }

    private func removeOverlays(name: String, matching: (PDFAnnotation) -> Bool) {
        guard let doc = pdfView.document else { return }
        var removed: [(PDFPage, PDFAnnotation)] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where matching(a) {
                page.removeAnnotation(a)
                removed.append((page, a))
            }
        }
        guard !removed.isEmpty else {
            infoAlert("Nothing to remove", "This document doesn\u{2019}t carry that mark.")
            return
        }
        docUndo.beginUndoGrouping()
        registerOverlayUndo(added: [], removed: removed, name: name)
        docUndo.endUndoGrouping()
        forceRefresh()
        sidebar.reload()
        flashSubtitle("Removed — \u{2318}Z to undo")
    }

    /// Inverse re-registers itself, so redo comes free — the pattern used by every other
    /// undoable mutation in this window.
    private func registerOverlayUndo(added: [(PDFPage, PDFAnnotation)],
                                     removed: [(PDFPage, PDFAnnotation)], name: String) {
        docUndo.registerUndo(withTarget: self) { me in
            for (page, a) in added { page.removeAnnotation(a) }
            for (page, a) in removed { page.addAnnotation(a) }
            me.registerOverlayUndo(added: removed, removed: added, name: name)
            me.forceRefresh()
            me.sidebar.reload()
        }
        docUndo.setActionName(name)
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if control === typewriterEditor?.field { cancelTypewriterEditor(); return true }
            if control === captionField { cancelCaptionEditor(); return true }
            if control === fieldTextSingle { cancelFieldTextEditor(); return true }
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicking anywhere outside the capsule places the text — Return is no longer the
        // only way out (Keno: the Enter-to-escape flow felt like a trap).
        if (obj.object as? NSTextField) === typewriterEditor?.field {
            commitTypewriterEditor()
            return
        }
        if (obj.object as? NSTextField) === captionField { commitCaptionEditor(); return }
        if (obj.object as? NSTextField) === fieldTextSingle { commitFieldTextEditor(); return }
        // Focus moved away from the typewriter editor (click elsewhere, tab out): place the
        // text. Return also lands here after the action fires; the nil-guard makes it a no-op.
        if (obj.object as? NSTextField) === typewriterEditor?.field { commitTypewriterEditor() }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === typewriterEditor?.field {
            typewriterEditor?.sizeToText()
            return
        }
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
