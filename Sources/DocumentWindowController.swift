// The document window: one window per PDF, Preview-style. Native unified toolbar (sidebar,
// zoom, Markup, Lock, Print, search, Save), a Markup tool strip that slides in beneath the
// title bar, and a sidebar that is the page organizer. No secondary windows, no "Home".
import AppKit
import PDFKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                      StampSelectionDelegate, PageSidebarDelegate, NSSearchFieldDelegate,
                                      NSMenuDelegate {

    private var pdfURL: URL
    private let pdfView = SigningPDFView()
    private let sidebar = PageSidebarController()
    private var searchField: NSSearchField?
    private weak var selected: ImageStampAnnotation?
    private var sheet: SignatureSheetController?

    private let docUndo = UndoManager()
    private var sliderStartBounds: CGRect?   // resize gesture start, so one drag = one undo step

    private var matches: [PDFSelection] = []
    private var matchIndex = 0
    // Clicking toolbar/menu chrome can clear the live selection before the action runs
    // (Tahoe focus behavior) — annotate actions fall back to the last real selection.
    private var lastSelection: PDFSelection?
    private var sidebarVisible = true
    private var markupOn = false
    private let sidebarWidth: CGFloat = 172

    // Markup strip controls
    private var markupAccessory: NSTitlebarAccessoryViewController?
    private let sizeSlider = NSSlider()
    private let removeButton = NSButton()
    private var markupButton: NSButton?
    private var shareButton: NSButton?
    private var titleChevron: NSButton?
    private var renamePopover: NSPopover?
    private let titleButton = NSButton(title: "", target: nil, action: nil)
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var titleContainer: NSView?

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
        layoutViews()

        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                               name: .PDFViewSelectionChanged, object: pdfView)
        pdfView.annotateMenuItems = { [weak self] page, point in
            self?.buildAnnotateMenuItems(page: page, point: point) ?? []
        }
        // A locked doc builds blank thumbnails; re-render everything once the password lands.
        NotificationCenter.default.addObserver(self, selector: #selector(documentUnlocked),
                                               name: .PDFDocumentDidUnlock, object: doc)
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

    @objc private func pageChanged() {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return }
        let index = doc.index(for: page)
        setSubtitle("Page \(index + 1) of \(doc.pageCount)")
        sidebar.highlight(pageIndex: index)
    }

    private func setSubtitle(_ s: String) {
        let edited = window?.isDocumentEdited == true ? " — Edited" : ""
        subtitleLabel.stringValue = s + edited
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
        static let tools = NSToolbarItem.Identifier("jack.tools")
        static let share = NSToolbarItem.Identifier("jack.share")
        static let highlight = NSToolbarItem.Identifier("jack.highlight")
        static let lock = NSToolbarItem.Identifier("jack.lock")
        static let print = NSToolbarItem.Identifier("jack.print")
        static let save = NSToolbarItem.Identifier("jack.save")
        static let search = NSToolbarItem.Identifier("jack.search")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.sidebar, .space, ItemID.undo, ItemID.redo, .flexibleSpace, ItemID.zoomOut, ItemID.zoomIn, .space,
         ItemID.highlight, ItemID.markup, ItemID.redact, ItemID.clean, ItemID.lock, ItemID.tools, ItemID.print, ItemID.share, .flexibleSpace, ItemID.search, ItemID.save]
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
        if window?.isDocumentEdited == true, let doc = pdfView.document {
            // Share what the user sees: edits flattened, comments carried.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("jack-share-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent(pdfURL.lastPathComponent)
            if exportCurrentState(doc, to: tmp) { url = tmp }
        }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    // MARK: - Rename (Preview-style: ⌄ chevron beside the title opens a rename popover)

    // Preview's look: the title text and its ⌄ are ONE control — hide the native title and
    // render our own title + chevron + "Page x of y" subtitle. Clicking either opens rename.
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
        let name = pdfURL.lastPathComponent
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
        whereLabel.frame = NSRect(x: 10, y: 30, width: 56, height: 16)
        v.addSubview(whereLabel)
        let folder = NSTextField(labelWithString: pdfURL.deletingLastPathComponent().lastPathComponent)
        folder.textColor = .secondaryLabelColor
        folder.frame = NSRect(x: 74, y: 30, width: 252, height: 16)
        v.addSubview(folder)

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
        } else if let content = window?.contentView {
            pop.show(relativeTo: NSRect(x: content.bounds.midX, y: content.bounds.maxY - 2, width: 1, height: 1),
                     of: content, preferredEdge: .maxY)
        }
        renamePopover = pop
        pop.contentViewController?.view.window?.makeFirstResponder(field)
    }

    private weak var renameField: NSTextField?

    @objc private func commitRename(_ sender: Any?) {
        guard let field = renameField else { return }
        let name = field.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let current = pdfURL.deletingPathExtension().lastPathComponent
        guard !name.isEmpty, name != current else { renamePopover?.close(); return }
        let dest = pdfURL.deletingLastPathComponent().appendingPathComponent(name + ".pdf")
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            infoAlert("Name taken", "A file named “\(dest.lastPathComponent)” already exists here.")
            return
        }
        do {
            try FileManager.default.moveItem(at: pdfURL, to: dest)
        } catch {
            infoAlert("Couldn’t rename", error.localizedDescription)
            return
        }
        renamePopover?.close()
        pdfURL = dest
        window?.title = dest.lastPathComponent
        window?.representedURL = dest
        layoutTitleAccessory()
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

    // From SigningPDFView after a rubber-band gesture: the mark exists — make it undoable
    // and force the repaint (PDFView's page cache doesn't reliably show annotation adds).
    func redactionAdded(_ ann: RedactionAnnotation) {
        docUndo.registerUndo(withTarget: self) { $0.removeRedactionMark(ann) }
        docUndo.setActionName("Mark Redaction")
        updateRedactCount()
        forceRefresh()
    }

    private func addRedactionMark(_ ann: RedactionAnnotation, to page: PDFPage, refresh: Bool = true) {
        page.addAnnotation(ann)
        docUndo.registerUndo(withTarget: self) { $0.removeRedactionMark(ann) }
        docUndo.setActionName("Mark Redaction")
        updateRedactCount()
        if refresh { forceRefresh() }
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

    private func markEdited() {
        window?.isDocumentEdited = true
        pageChanged()   // refresh the "— Edited" subtitle
    }

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
            if self.exportCurrentState(doc, to: out) {
                self.window?.isDocumentEdited = false
                self.pageChanged()
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

    // MARK: - Compress

    @objc func compressDocument(_ sender: Any?) {
        guard let doc = pdfView.document, let window = window else { return }
        guard let data = doc.dataRepresentation(), let workCopy = PDFDocument(data: data) else {
            infoAlert("Couldn’t prepare document", "The document couldn’t be copied for compression.")
            return
        }
        let originalSize = data.count
        let panel = NSSavePanel()
        panel.nameFieldStringValue = pdfURL.deletingPathExtension().lastPathComponent + "-compressed.pdf"
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
        panel.nameFieldStringValue = pdfURL.deletingPathExtension().lastPathComponent + "-searchable.pdf"
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
        panel.nameFieldStringValue = pdfURL.deletingPathExtension().lastPathComponent + "-bates.pdf"
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
        panel.nameFieldStringValue = pdfURL.deletingPathExtension().lastPathComponent + "-watermarked.pdf"
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
        panel.nameFieldStringValue = pdfURL.deletingPathExtension().lastPathComponent + "-locked.pdf"
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
