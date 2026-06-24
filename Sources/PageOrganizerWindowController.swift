// Page Organizer — two panes:
//   • Main  = Source pages (everything you've opened/added)
//   • Left  = New PDF (your output, built live)
// Drag pages Source → New PDF (or Add Selected / Add All); reorder/rotate/remove inside
// New PDF; Save it. "Save Selected As…" handles pure extract from the source.
import AppKit
import PDFKit

final class PageOrganizerWindowController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private static let pageType = NSPasteboard.PasteboardType("net.thinkopen.jack.page")

    private var sourcePages: [PDFPage]
    private var trayPages: [PDFPage] = []
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
        win.title = "Jack — Organize Pages"
        win.center()
        super.init(window: win)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout

    private func build() {
        guard let content = window?.contentView else { return }
        let H = content.bounds.height
        let sidebarW: CGFloat = 320

        // Left pane — New PDF
        let left = NSView(frame: NSRect(x: 0, y: 0, width: sidebarW, height: H))
        left.autoresizingMask = [.height]
        content.addSubview(left)

        addHeader("New PDF", to: left, width: 288)
        let rotate = button("Rotate", #selector(trayRotate), NSRect(x: 16, y: H - 72, width: 90, height: 28), [.minYMargin])
        let remove = button("Remove", #selector(trayRemove), NSRect(x: 112, y: H - 72, width: 90, height: 28), [.minYMargin])
        left.addSubview(rotate); left.addSubview(remove)
        let saveTray = button("Save New PDF…", #selector(saveTray), NSRect(x: 16, y: 16, width: 288, height: 32), [.width])
        saveTray.keyEquivalent = "s"
        left.addSubview(saveTray)
        left.addSubview(scroll(trayCV, layout(itemW: 138, itemH: 184),
                               frame: NSRect(x: 12, y: 56, width: 296, height: H - 80 - 56)))

        // Divider
        let divider = NSBox(frame: NSRect(x: sidebarW, y: 0, width: 1, height: H))
        divider.boxType = .separator
        divider.autoresizingMask = [.height]
        content.addSubview(divider)

        // Right pane — Source pages
        let main = NSView(frame: NSRect(x: sidebarW + 1, y: 0, width: content.bounds.width - sidebarW - 1, height: H))
        main.autoresizingMask = [.width, .height]
        content.addSubview(main)

        addHeader("Source pages", to: main, width: 400)
        var x: CGFloat = 16
        for (title, sel, w) in [("Add Files…", #selector(addFiles), CGFloat(104)),
                                ("Add Selected →", #selector(addSelected), 132),
                                ("Add All →", #selector(addAll), 96),
                                ("Save Selected As…", #selector(saveSelectedAs), 150)] {
            main.addSubview(button(title, sel, NSRect(x: x, y: H - 72, width: w, height: 28), [.minYMargin]))
            x += w + 8
        }
        main.addSubview(scroll(sourceCV, layout(itemW: 150, itemH: 196),
                               frame: NSRect(x: 12, y: 16, width: main.bounds.width - 24, height: H - 80 - 16),
                               flexible: true))

        configure(sourceCV, isTray: false)
        configure(trayCV, isTray: true)
    }

    private func addHeader(_ text: String, to view: NSView, width: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.frame = NSRect(x: 16, y: view.bounds.height - 34, width: width, height: 22)
        label.autoresizingMask = [.width, .minYMargin]
        view.addSubview(label)
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
        let page = pages(cv)[indexPath.item]
        item.configure(thumbnail(for: page), label: "\(indexPath.item + 1)")
        return item
    }

    // MARK: drag & drop

    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

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
            // Copy source pages into the New PDF.
            let add = sourceDrag.compactMap { sourcePages[$0].copy() as? PDFPage }
            guard !add.isEmpty else { return false }
            target = min(max(0, target), trayPages.count)
            trayPages.insert(contentsOf: add, at: target)
            sourceDrag = []
            reloadTray(select: target..<(target + add.count))
        } else {
            // Reorder within the New PDF.
            guard !trayDrag.isEmpty else { return false }
            let moving = trayDrag.map { trayPages[$0] }
            for i in trayDrag.sorted(by: >) { trayPages.remove(at: i); if i < target { target -= 1 } }
            target = min(max(0, target), trayPages.count)
            trayPages.insert(contentsOf: moving, at: target)
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
    }

    private func button(_ title: String, _ action: Selector, _ frame: NSRect, _ mask: NSView.AutoresizingMask) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.frame = frame
        b.autoresizingMask = mask
        return b
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
        let sel = selected(sourceCV)
        guard !sel.isEmpty else { infoAlert("Select pages", "Select source pages to add to your New PDF."); return }
        let add = sel.compactMap { sourcePages[$0].copy() as? PDFPage }
        let start = trayPages.count
        trayPages.append(contentsOf: add)
        reloadTray(select: start..<(start + add.count))
    }

    @objc private func addAll() {
        let add = sourcePages.compactMap { $0.copy() as? PDFPage }
        let start = trayPages.count
        trayPages.append(contentsOf: add)
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
        for i in sel.sorted(by: >) { trayPages.remove(at: i) }
        reloadTray()
    }

    @objc private func saveSelectedAs() {
        let sel = selected(sourceCV)
        guard !sel.isEmpty else { infoAlert("Select pages first", "Choose source pages to save as a new PDF."); return }
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
