// Page Organizer — two panes:
//   • Main  = Source pages (everything you've opened/added)
//   • Left  = New PDF (your output, built live)
// Drag pages Source → New PDF (or Add Selected / Add All); reorder/rotate/remove inside
// New PDF; Save it. "Save Selected As…" handles pure extract from the source.
import AppKit
import PDFKit

final class PageOrganizerWindowController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSWindowDelegate, NSToolbarDelegate {
    private static let pageType = NSPasteboard.PasteboardType("net.thinkopen.jack.page")
    var onCancel: (() -> Void)?

    private var sourcePages: [PDFPage]
    private var trayPages: [PDFPage] = []
    /// Physical truth (Keno, 2026-08-30): a page moved into the New PDF leaves its source
    /// slot EMPTY — nothing reflows, nothing renumbers. Removing it from the New PDF puts
    /// it back, and an empty slot can't be moved twice.
    private var takenSource: Set<Int> = []
    private var trayOrigins: [Int] = []      // trayPages[i] came from sourcePages[trayOrigins[i]]
    private var thumbCache: [ObjectIdentifier: NSImage] = [:]

    private let sourceCV = NSCollectionView()
    private let trayCV = NSCollectionView()
    private var sourceDrag: [Int] = []
    private var trayDrag: [Int] = []

    init(pages: [PDFPage]) {
        self.sourcePages = pages
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Organize Pages"
        win.center()
        super.init(window: win)
        win.delegate = self
        // The v2.8 grammar: unified toolbar, same symbol pipeline as the document window.
        let toolbar = NSToolbar(identifier: "JackOrganizerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        win.toolbar = toolbar
        if #available(macOS 11.0, *) { win.toolbarStyle = .unified }
        build()
    }

    @objc private func backHome() { onCancel?() }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            AppDelegate.organizers.removeAll { $0 === self }
            AppDelegate.updateActivationPolicy()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: toolbar (v2.8 grammar — same symbol pipeline as the document window)

    private enum ItemID {
        static let home = NSToolbarItem.Identifier("org.home")
        static let addFiles = NSToolbarItem.Identifier("org.addFiles")
        static let save = NSToolbarItem.Identifier("org.save")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.home, ItemID.addFiles, .flexibleSpace, ItemID.save]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ItemID.home:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = DocumentWindowController.toolbarSymbol(["house"], "Home")
            item.label = "Home"
            item.toolTip = "Back to Jack's launcher"
            item.target = self
            item.action = #selector(backHome)
            item.isBordered = true
            return item
        case ItemID.addFiles:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = DocumentWindowController.toolbarSymbol(["plus"], "Add Files")
            item.label = "Add Files"
            item.toolTip = "Add PDFs and photos to the source pages"
            item.target = self
            item.action = #selector(addFiles)
            item.isBordered = true
            return item
        case ItemID.save:
            let item = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(title: "Save New PDF…", target: self, action: #selector(saveTray))
            b.bezelStyle = .texturedRounded
            b.keyEquivalent = "s"
            item.view = b
            item.label = "Save New PDF"
            item.toolTip = "Save the pages you've assembled (⌘S)"
            return item
        default: return nil
        }
    }

    // MARK: layout

    private let trayEmptyHint = NSTextField(wrappingLabelWithString:
        "Drag pages here to build your PDF — or use ← Add Selected")

    private func build() {
        guard let content = window?.contentView else { return }
        let fullW = content.bounds.width
        let cH = content.bounds.height
        let sidebarW: CGFloat = 320

        // Left pane — New PDF (the output, built live)
        let left = NSView(frame: NSRect(x: 0, y: 0, width: sidebarW, height: cH))
        left.autoresizingMask = [.height]
        content.addSubview(left)

        addHeader("NEW PDF", to: left)
        left.addSubview(chip("Rotate", "rotate.right", #selector(trayRotate),
                             NSRect(x: 16, y: cH - 64, width: 84, height: 26)))
        left.addSubview(chip("Remove", "trash", #selector(trayRemove),
                             NSRect(x: 106, y: cH - 64, width: 92, height: 26)))
        left.addSubview(scroll(trayCV, layout(itemW: 138, itemH: 184),
                               frame: NSRect(x: 12, y: 12, width: 296, height: cH - 76 - 12)))
        trayEmptyHint.font = .systemFont(ofSize: 12)
        trayEmptyHint.textColor = .tertiaryLabelColor
        trayEmptyHint.alignment = .center
        trayEmptyHint.frame = NSRect(x: 24, y: cH / 2 - 24, width: sidebarW - 48, height: 40)
        trayEmptyHint.autoresizingMask = [.minYMargin, .maxYMargin]
        left.addSubview(trayEmptyHint)

        // Divider
        let divider = NSBox(frame: NSRect(x: sidebarW, y: 0, width: 1, height: cH))
        divider.boxType = .separator
        divider.autoresizingMask = [.height]
        content.addSubview(divider)

        // Right pane — Source pages
        let main = NSView(frame: NSRect(x: sidebarW + 1, y: 0, width: fullW - sidebarW - 1, height: cH))
        main.autoresizingMask = [.width, .height]
        content.addSubview(main)

        addHeader("SOURCE PAGES", to: main)
        var x: CGFloat = 16
        // The New PDF pane is on the LEFT — the arrows finally point where pages go.
        for (title, symbol, sel, w) in [("Add Selected", "arrow.left", #selector(addSelected), CGFloat(122)),
                                        ("Add All", "arrow.left.to.line", #selector(addAll), 96),
                                        ("Save Selected As…", "square.and.arrow.down", #selector(saveSelectedAs), 168)] {
            main.addSubview(chip(title, symbol, sel, NSRect(x: x, y: cH - 64, width: w, height: 26)))
            x += w + 8
        }
        main.addSubview(scroll(sourceCV, layout(itemW: 150, itemH: 196),
                               frame: NSRect(x: 12, y: 12, width: main.bounds.width - 24, height: cH - 76 - 12),
                               flexible: true))

        configure(sourceCV, isTray: false)
        configure(trayCV, isTray: true)
        syncTrayHint()
    }

    private func syncTrayHint() { trayEmptyHint.isHidden = !trayPages.isEmpty }

    private func addHeader(_ text: String, to view: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: 17, y: view.bounds.height - 32, width: 200, height: 14)
        label.autoresizingMask = [.minYMargin]
        view.addSubview(label)
    }

    /// The mode-row chip, verbatim from the document window's grammar.
    private func chip(_ title: String, _ symbol: String, _ action: Selector, _ frame: NSRect) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.frame = frame
        b.autoresizingMask = [.minYMargin]
        return b
    }

    private func layout(itemW: CGFloat, itemH: CGFloat) -> NSCollectionViewFlowLayout {
        let l = NSCollectionViewFlowLayout()
        l.itemSize = NSSize(width: itemW, height: itemH)
        l.minimumInteritemSpacing = 12
        l.minimumLineSpacing = 14
        l.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        return l
    }

    private func scroll(_ cv: NSCollectionView, _ l: NSCollectionViewFlowLayout, frame: NSRect, flexible: Bool = false) -> NSScrollView {
        cv.collectionViewLayout = l
        let s = NSScrollView(frame: frame)
        s.autoresizingMask = flexible ? [.width, .height] : [.width, .height]
        s.hasVerticalScroller = true
        s.documentView = cv
        return s
    }

    private func configure(_ cv: NSCollectionView, isTray: Bool) {
        cv.dataSource = self
        cv.delegate = self
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.allowsEmptySelection = true
        cv.backgroundColors = [isTray ? NSColor.windowBackgroundColor : NSColor.underPageBackgroundColor]
        cv.register(PageThumbnailItem.self, forItemWithIdentifier: PageThumbnailItem.id)
        cv.registerForDraggedTypes([Self.pageType])
        cv.setDraggingSourceOperationMask(isTray ? .move : .copy, forLocal: true)
    }

    // MARK: data source

    private func pages(_ cv: NSCollectionView) -> [PDFPage] { cv === trayCV ? trayPages : sourcePages }

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { pages(cv).count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: PageThumbnailItem.id, for: indexPath) as! PageThumbnailItem
        if cv === sourceCV, takenSource.contains(indexPath.item) {
            item.configureTaken(label: "\(indexPath.item + 1)")
        } else {
            let page = pages(cv)[indexPath.item]
            item.configure(thumbnail(for: page), label: "\(indexPath.item + 1)")
        }
        return item
    }

    // MARK: drag & drop

    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        cv !== sourceCV || indexPaths.allSatisfy { !takenSource.contains($0.item) }
    }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(indexPath.item), forType: Self.pageType)
        return item
    }

    func collectionView(_ cv: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        let idx = indexPaths.map { $0.item }.sorted()
        if cv === trayCV { trayDrag = idx } else { sourceDrag = idx }
    }

    func collectionView(_ cv: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard cv === trayCV else { return [] }   // only the New PDF pane accepts drops
        if dropOperation.pointee == .on { dropOperation.pointee = .before }
        return (draggingInfo.draggingSource as? NSCollectionView) === sourceCV ? .copy : .move
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard cv === trayCV else { return false }
        var target = indexPath.item
        if (draggingInfo.draggingSource as? NSCollectionView) === sourceCV {
            // MOVE source pages into the New PDF — their slots stay behind, empty.
            let fresh = sourceDrag.filter { !takenSource.contains($0) }
            let add = fresh.compactMap { sourcePages[$0].copy() as? PDFPage }
            guard !add.isEmpty else { return false }
            target = min(max(0, target), trayPages.count)
            trayPages.insert(contentsOf: add, at: target)
            trayOrigins.insert(contentsOf: fresh, at: target)
            fresh.forEach { takenSource.insert($0) }
            sourceDrag = []
            reloadSource()
            reloadTray(select: target..<(target + add.count))
        } else {
            // Reorder within the New PDF (origins travel with their pages).
            guard !trayDrag.isEmpty else { return false }
            let moving = trayDrag.map { trayPages[$0] }
            let movingOrigins = trayDrag.map { trayOrigins[$0] }
            for i in trayDrag.sorted(by: >) {
                trayPages.remove(at: i); trayOrigins.remove(at: i)
                if i < target { target -= 1 }
            }
            target = min(max(0, target), trayPages.count)
            trayPages.insert(contentsOf: moving, at: target)
            trayOrigins.insert(contentsOf: movingOrigins, at: target)
            trayDrag = []
            reloadTray(select: target..<(target + moving.count))
        }
        return true
    }

    // MARK: helpers

    private func thumbnail(for page: PDFPage) -> NSImage {
        let key = ObjectIdentifier(page)
        if let c = thumbCache[key] { return c }
        let t = page.thumbnail(of: NSSize(width: 122, height: 158), for: .mediaBox)
        thumbCache[key] = t
        return t
    }

    private func selected(_ cv: NSCollectionView) -> [Int] { cv.selectionIndexPaths.map { $0.item }.sorted() }
    private func reloadSource() { sourceCV.reloadData() }
    private func reloadTray(select range: Range<Int>? = nil) {
        trayCV.reloadData()
        if let r = range { trayCV.selectionIndexPaths = Set(r.map { IndexPath(item: $0, section: 0) }) }
        syncTrayHint()
    }

    // MARK: actions

    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.message = "Add PDFs and photos"; panel.prompt = "Add"
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf, .image] }
        guard panel.runModal() == .OK else { return }
        let added = loadPages(from: panel.urls)
        guard !added.isEmpty else { return }
        sourcePages.append(contentsOf: added)
        reloadSource()
    }

    @objc private func addSelected() {
        let sel = selected(sourceCV).filter { !takenSource.contains($0) }
        guard !sel.isEmpty else { infoAlert("Select pages", "Select source pages to add to your New PDF — empty slots have already been moved."); return }
        take(sel)
    }

    @objc private func addAll() {
        take((0..<sourcePages.count).filter { !takenSource.contains($0) })
    }

    /// Move source pages (by index) into the New PDF, leaving their slots empty.
    private func take(_ indices: [Int]) {
        let add = indices.compactMap { sourcePages[$0].copy() as? PDFPage }
        guard !add.isEmpty else { return }
        let start = trayPages.count
        trayPages.append(contentsOf: add)
        trayOrigins.append(contentsOf: indices)
        indices.forEach { takenSource.insert($0) }
        reloadSource()
        reloadTray(select: start..<(start + add.count))
    }

    @objc private func trayRotate() {
        let sel = selected(trayCV)
        guard !sel.isEmpty else { return }
        for i in sel { trayPages[i].rotation = (trayPages[i].rotation + 90) % 360; thumbCache[ObjectIdentifier(trayPages[i])] = nil }
        reloadTray(select: sel.first!..<(sel.last! + 1))
    }

    @objc private func trayRemove() {
        let sel = selected(trayCV)
        guard !sel.isEmpty else { return }
        // Removing from the New PDF puts the page BACK — its source slot refills.
        for i in sel.sorted(by: >) {
            takenSource.remove(trayOrigins[i])
            trayPages.remove(at: i)
            trayOrigins.remove(at: i)
        }
        reloadSource()
        reloadTray()
    }

    @objc private func saveSelectedAs() {
        let sel = selected(sourceCV).filter { !takenSource.contains($0) }
        guard !sel.isEmpty else { infoAlert("Select pages first", "Choose source pages to save as a new PDF — empty slots have already been moved."); return }
        let doc = PDFDocument()
        for (n, i) in sel.enumerated() { if let c = sourcePages[i].copy() as? PDFPage { doc.insert(c, at: n) } }
        save(doc, suggested: "Extracted.pdf")
    }

    @objc private func saveTray() {
        guard !trayPages.isEmpty else { infoAlert("New PDF is empty", "Add pages to your New PDF first — drag them in, or use Add Selected / Add All."); return }
        let doc = PDFDocument()
        for (n, p) in trayPages.enumerated() { if let c = p.copy() as? PDFPage { doc.insert(c, at: n) } }
        save(doc, suggested: "New.pdf")
    }

    private func save(_ doc: PDFDocument, suggested: String) {
        guard let window = window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            if doc.write(to: url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                NSSound(named: "Glass")?.play()
            } else {
                infoAlert("Save failed", "Couldn’t write the PDF.")
            }
        }
    }
}
