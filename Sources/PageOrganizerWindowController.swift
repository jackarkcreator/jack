// Page Organizer: combine PDFs/photos, reorder, rotate, delete, extract selected pages, save.
import AppKit
import PDFKit

final class PageOrganizerWindowController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private static let pageType = NSPasteboard.PasteboardType("net.thinkopen.jack.page")
    private var pages: [PDFPage]
    private var thumbCache: [ObjectIdentifier: NSImage] = [:]
    private var draggedIndexes: [Int] = []
    private let collectionView = NSCollectionView()

    init(pages: [PDFPage]) {
        self.pages = pages
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Jack — Organize Pages"
        win.center()
        super.init(window: win)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let barH: CGFloat = 48
        let bar = NSView(frame: NSRect(x: 0, y: content.bounds.height - barH, width: content.bounds.width, height: barH))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.addSubview(bar)

        func mk(_ title: String, _ action: Selector, _ x: CGFloat, _ w: CGFloat, rightAnchored: Bool = false) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.frame = NSRect(x: x, y: 9, width: w, height: 30)
            if rightAnchored { b.autoresizingMask = [.minXMargin] }
            bar.addSubview(b)
            return b
        }
        _ = mk("Add Files…", #selector(addFiles), 16, 104)
        _ = mk("◀ Move", #selector(movePagesLeft), 128, 78)
        _ = mk("Move ▶", #selector(movePagesRight), 212, 78)
        _ = mk("Rotate", #selector(rotatePages), 296, 78)
        _ = mk("Delete", #selector(deletePages), 380, 78)
        _ = mk("Save PDF…", #selector(saveAll), content.bounds.width - 150, 134, rightAnchored: true)
        _ = mk("Extract Selected…", #selector(extractSelected), content.bounds.width - 310, 150, rightAnchored: true)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 150, height: 196)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [NSColor.underPageBackgroundColor]
        collectionView.register(PageThumbnailItem.self, forItemWithIdentifier: PageThumbnailItem.id)
        collectionView.registerForDraggedTypes([Self.pageType])
        collectionView.setDraggingSourceOperationMask([.move], forLocal: true)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - barH))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.documentView = collectionView
        content.addSubview(scroll)
    }

    // MARK: data source

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { pages.count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: PageThumbnailItem.id, for: indexPath) as! PageThumbnailItem
        let page = pages[indexPath.item]
        item.configure(thumbnail(for: page), label: "Page \(indexPath.item + 1)")
        return item
    }

    // MARK: drag-to-reorder

    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(indexPath.item), forType: Self.pageType)
        return item
    }

    func collectionView(_ cv: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        draggedIndexes = indexPaths.map { $0.item }.sorted()
    }

    func collectionView(_ cv: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        if dropOperation.pointee == .on { dropOperation.pointee = .before }
        return draggedIndexes.isEmpty ? [] : .move
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard !draggedIndexes.isEmpty else { return false }
        var target = indexPath.item
        let moving = draggedIndexes.map { pages[$0] }
        for i in draggedIndexes.sorted(by: >) {
            pages.remove(at: i)
            if i < target { target -= 1 }
        }
        target = min(max(0, target), pages.count)
        pages.insert(contentsOf: moving, at: target)
        draggedIndexes = []
        reload(selecting: target..<(target + moving.count))
        return true
    }

    private func thumbnail(for page: PDFPage) -> NSImage {
        let key = ObjectIdentifier(page)
        if let cached = thumbCache[key] { return cached }
        let t = page.thumbnail(of: NSSize(width: 134, height: 162), for: .mediaBox)
        thumbCache[key] = t
        return t
    }

    private func selectedIndexes() -> [Int] {
        collectionView.selectionIndexPaths.map { $0.item }.sorted()
    }

    private func reload(selecting range: Range<Int>? = nil) {
        collectionView.reloadData()
        if let range = range {
            collectionView.selectionIndexPaths = Set(range.map { IndexPath(item: $0, section: 0) })
        }
    }

    // MARK: actions

    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Add PDFs and photos"
        panel.prompt = "Add"
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf, .image] }
        guard panel.runModal() == .OK else { return }
        let added = loadPages(from: panel.urls)
        guard !added.isEmpty else { return }
        pages.append(contentsOf: added)
        reload()
    }

    @objc private func movePagesLeft() { move(by: -1) }
    @objc private func movePagesRight() { move(by: 1) }

    private func move(by delta: Int) {
        let sel = selectedIndexes()
        guard !sel.isEmpty else { return }
        let moving = sel.map { pages[$0] }
        for i in sel.reversed() { pages.remove(at: i) }
        let insert = min(max(0, sel[0] + delta), pages.count)
        pages.insert(contentsOf: moving, at: insert)
        reload(selecting: insert..<(insert + moving.count))
    }

    @objc private func rotatePages() {
        let sel = selectedIndexes()
        guard !sel.isEmpty else { return }
        for i in sel {
            pages[i].rotation = (pages[i].rotation + 90) % 360
            thumbCache[ObjectIdentifier(pages[i])] = nil
        }
        reload(selecting: sel.first!..<(sel.last! + 1))
    }

    @objc private func deletePages() {
        let sel = selectedIndexes()
        guard !sel.isEmpty else { return }
        for i in sel.sorted(by: >) { pages.remove(at: i) }
        reload()
    }

    @objc private func extractSelected() {
        let sel = selectedIndexes()
        guard !sel.isEmpty else {
            infoAlert("Select pages first", "Choose the pages you want to extract into a new PDF.")
            return
        }
        let doc = PDFDocument()
        for (n, i) in sel.enumerated() { if let c = pages[i].copy() as? PDFPage { doc.insert(c, at: n) } }
        save(doc, suggested: "Extracted.pdf")
    }

    @objc private func saveAll() {
        guard !pages.isEmpty else { return }
        let doc = PDFDocument()
        for (n, p) in pages.enumerated() { if let c = p.copy() as? PDFPage { doc.insert(c, at: n) } }
        save(doc, suggested: "Combined.pdf")
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
