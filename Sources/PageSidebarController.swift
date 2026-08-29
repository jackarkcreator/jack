// The document sidebar IS the organizer: drag thumbnails to reorder pages, right-click to
// rotate/delete/extract, drop PDFs or photos in to merge. Edits mutate the live PDFDocument.
import AppKit
import PDFKit

protocol PageSidebarDelegate: AnyObject {
    func sidebarDidSelectPage(_ index: Int)
    func sidebarDidModifyDocument()
    func sidebarRequestsExtract(_ indexes: [Int])
}

private let pageDragType = NSPasteboard.PasteboardType("net.thinkopen.jack.page-index")

final class SidebarCollectionView: NSCollectionView {
    var onContextMenu: ((Int, NSEvent) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return onContextMenu?(indexPath.item, event)
    }
}

final class PageSidebarController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    weak var document: PDFDocument?
    weak var delegate: PageSidebarDelegate?
    var undoProvider: (() -> UndoManager?)?
    let scrollView = NSScrollView()
    private let collectionView = SidebarCollectionView()

    override init() {
        super.init()
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 140, height: 180)
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        layout.minimumLineSpacing = 10
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(PageThumbnailItem.self, forItemWithIdentifier: PageThumbnailItem.id)
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.registerForDraggedTypes([pageDragType, .fileURL])
        collectionView.onContextMenu = { [weak self] index, _ in self?.contextMenu(clicked: index) }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
    }

    func reload() { collectionView.reloadData() }

    // Keep the sidebar selection in step with the visible page.
    func highlight(pageIndex: Int) {
        guard pageIndex >= 0, pageIndex < (document?.pageCount ?? 0) else { return }
        let path = IndexPath(item: pageIndex, section: 0)
        collectionView.deselectItems(at: collectionView.selectionIndexPaths)
        collectionView.selectItems(at: [path], scrollPosition: .nearestHorizontalEdge)
    }

    // MARK: - Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        document?.pageCount ?? 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PageThumbnailItem.id, for: indexPath)
        guard let tile = item as? PageThumbnailItem, let page = document?.page(at: indexPath.item) else { return item }
        tile.configure(page.thumbnail(of: NSSize(width: 120, height: 156), for: .mediaBox), label: "\(indexPath.item + 1)")
        return tile
    }

    // MARK: - Selection

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let first = indexPaths.min() { delegate?.sidebarDidSelectPage(first.item) }
    }

    // MARK: - Drag to reorder + drop files to merge

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let pb = NSPasteboardItem()
        pb.setString(String(indexPath.item), forType: pageDragType)
        return pb
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        dropOperation.pointee = .before
        if draggingInfo.draggingPasteboard.types?.contains(pageDragType) == true { return .move }
        if draggingInfo.draggingPasteboard.types?.contains(.fileURL) == true { return .copy }
        return []
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let doc = document else { return false }
        let dest = indexPath.item

        if let s = draggingInfo.draggingPasteboard.string(forType: pageDragType), let src = Int(s) {
            guard src != dest, src != dest - 1 else { return true } // dropped back in place
            movePage(from: src, to: src < dest ? dest - 1 : dest)
            return true
        }

        let urls = (draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        let pages = loadPages(from: urls)
        guard !pages.isEmpty else { return false }
        insertPages(pages, at: min(dest, doc.pageCount))
        return true
    }

    // MARK: - Undoable primitives (each registers its own inverse, so redo comes free)

    private func registerUndo(_ name: String, _ inverse: @escaping (PageSidebarController) -> Void) {
        guard let um = undoProvider?() else { return }
        um.registerUndo(withTarget: self) { inverse($0) }
        um.setActionName(name)
    }

    private func movePage(from src: Int, to dest: Int) {
        guard let doc = document, let page = doc.page(at: src) else { return }
        doc.removePage(at: src)
        doc.insert(page, at: dest)
        registerUndo("Move Page") { $0.movePage(from: dest, to: src) }
        changed()
    }

    private func insertPages(_ pages: [PDFPage], at index: Int) {
        guard let doc = document, !pages.isEmpty else { return }
        for (i, p) in pages.enumerated() { doc.insert(p, at: min(index + i, doc.pageCount)) }
        registerUndo("Add Pages") { $0.removePages(at: Array(index..<(index + pages.count))) }
        changed()
    }

    private func removePages(at indexes: [Int]) {
        guard let doc = document else { return }
        var removed: [(Int, PDFPage)] = []
        for i in indexes.sorted(by: >) {
            guard let p = doc.page(at: i) else { continue }
            removed.append((i, p))
            doc.removePage(at: i)
        }
        guard !removed.isEmpty else { return }
        registerUndo("Delete \(removed.count == 1 ? "Page" : "Pages")") { me in
            guard let d = me.document else { return }
            for (i, p) in removed.reversed() { d.insert(p, at: min(i, d.pageCount)) }
            me.registerUndo("Delete Pages") { $0.removePages(at: indexes) }
            me.changed()
        }
        changed()
    }

    // MARK: - Context menu

    private func contextMenu(clicked: Int) -> NSMenu {
        // Act on the whole selection when the clicked tile is part of it; otherwise just the clicked tile.
        let selected = collectionView.selectionIndexPaths.map { $0.item }.sorted()
        let targets = selected.contains(clicked) ? selected : [clicked]

        let menu = NSMenu()
        let noun = targets.count == 1 ? "Page" : "\(targets.count) Pages"
        menu.addItem(action("Rotate \(noun)") { [weak self] in self?.rotate(targets) })
        menu.addItem(action("Extract \(noun) to New PDF…") { [weak self] in self?.delegate?.sidebarRequestsExtract(targets) })
        menu.addItem(.separator())
        let del = action("Delete \(noun)") { [weak self] in self?.delete(targets) }
        if (document?.pageCount ?? 0) <= targets.count { del.isEnabled = false } // never delete every page
        menu.addItem(del)
        return menu
    }

    private func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runHandler(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuHandler(handler)
        return item
    }

    private final class MenuHandler { let run: () -> Void; init(_ r: @escaping () -> Void) { run = r } }
    @objc private func runHandler(_ sender: NSMenuItem) { (sender.representedObject as? MenuHandler)?.run() }

    private func rotate(_ indexes: [Int], by degrees: Int = 90) {
        for i in indexes { document?.page(at: i)?.rotation += degrees }
        registerUndo("Rotate") { $0.rotate(indexes, by: -degrees) }
        changed()
    }

    private func delete(_ indexes: [Int]) {
        guard let doc = document, doc.pageCount > indexes.count else { return }
        removePages(at: indexes)
    }

    private func changed() {
        collectionView.reloadData()
        delegate?.sidebarDidModifyDocument()
    }
}
