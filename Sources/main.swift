// Jack — a lightweight PDF utility that lives in the menu bar: combine photos, fill & sign, organize.
// ThinkOpen Inc.
import Cocoa
import ImageIO
import PDFKit
import ServiceManagement
import UniformTypeIdentifiers

let MAX_EDGE: CGFloat = 1600
let JPEG_QUALITY: CGFloat = 0.72

func infoAlert(_ title: String, _ body: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = body
    a.alertStyle = .informational
    a.addButton(withTitle: "OK")
    a.runModal()
}

func isImageURL(_ url: URL) -> Bool {
    if #available(macOS 11.0, *),
       let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
        return type.conforms(to: .image)
    }
    let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp"]
    return exts.contains(url.pathExtension.lowercased())
}

func isPDFURL(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }

func downscaleImage(_ url: URL) -> NSImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: MAX_EDGE,
        kCGImageSourceShouldCacheImmediately: true
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: JPEG_QUALITY]),
          let img = NSImage(data: jpeg) else {
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    return img
}

func loadPages(from urls: [URL]) -> [PDFPage] {
    var pages: [PDFPage] = []
    for url in urls {
        if isPDFURL(url), let doc = PDFDocument(url: url) {
            for i in 0..<doc.pageCount {
                if let p = doc.page(at: i), let copy = p.copy() as? PDFPage { pages.append(copy) }
            }
        } else if isImageURL(url), let img = downscaleImage(url), let p = PDFPage(image: img) {
            pages.append(p)
        }
    }
    return pages
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didHandleOpen = false
    private var pending: [URL] = []
    private var scheduled = false
    static var signers: [SigningWindowController] = []
    static var organizers: [PageOrganizerWindowController] = []

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let popoverVC = HomePopoverViewController()

    // Drop files on the menu bar icon / "Open With… Jack". Coalesce split open calls.
    func application(_ application: NSApplication, open urls: [URL]) {
        didHandleOpen = true
        pending.append(contentsOf: urls)
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            let batch = self.pending; self.pending = []; self.scheduled = false
            self.route(batch)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        configureLoginOnFirstRun()
        // Show the launcher on a plain launch so the menu bar item is discoverable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, !self.didHandleOpen else { return }
            self.showPopover()
        }
    }

    // Stay resident in the menu bar after document windows close.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func route(_ urls: [URL]) {
        let pdfs = urls.filter(isPDFURL)
        let images = urls.filter(isImageURL)
        if pdfs.count == 1 && images.isEmpty {
            openSigning(pdfs[0])
        } else if !pdfs.isEmpty {
            openOrganizer(urls)
        } else if !images.isEmpty {
            makeImagePDF(images)
        } else {
            showPopover()
        }
    }

    // MARK: - Menu bar item & popover

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        if let img = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Jack") {
            img.isTemplate = true
            button.image = img
        }
        let overlay = StatusDropView(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClick = { [weak self] in self?.togglePopover() }
        overlay.onDrop = { [weak self] urls in self?.popover.performClose(nil); self?.route(urls) }
        button.addSubview(overlay)
    }

    private func setupPopover() {
        popoverVC.onPhotos = { [weak self] in self?.popover.performClose(nil); self?.pickPhotos() }
        popoverVC.onSign = { [weak self] in self?.popover.performClose(nil); self?.pickSign() }
        popoverVC.onOrganize = { [weak self] in self?.popover.performClose(nil); self?.pickOrganize() }
        popoverVC.onQuit = { NSApp.terminate(nil) }
        popoverVC.onToggleLogin = { [weak self] on in self?.setLogin(on) }
        popover.contentViewController = popoverVC
        popover.behavior = .transient
    }

    private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popoverVC.loginEnabled = isLoginEnabled()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Login item

    private func isLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }
    private func setLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        catch { /* best effort; toggle reflects actual status on next open */ }
    }
    private func configureLoginOnFirstRun() {
        let key = "jack.loginConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        setLogin(true)
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: - Pickers

    private enum PickKind { case photos, pdf, both }

    private func runPicker(_ kind: PickKind, multi: Bool, message: String, prompt: String,
                           _ completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multi
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = message
        panel.prompt = prompt
        if #available(macOS 11.0, *) {
            switch kind {
            case .photos: panel.allowedContentTypes = [.image]
            case .pdf:    panel.allowedContentTypes = [.pdf]
            case .both:   panel.allowedContentTypes = [.pdf, .image]
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { completion(panel.urls) }
    }

    private func pickPhotos() {
        runPicker(.photos, multi: true, message: "Choose photos to combine into one PDF", prompt: "Make PDF") {
            [weak self] in self?.makeImagePDF($0)
        }
    }
    private func pickSign() {
        runPicker(.pdf, multi: false, message: "Choose a PDF to fill or sign", prompt: "Open") {
            [weak self] in if let u = $0.first { self?.openSigning(u) }
        }
    }
    private func pickOrganize() {
        runPicker(.both, multi: true, message: "Choose PDFs and photos to combine, reorder, or extract pages", prompt: "Open") {
            [weak self] in self?.openOrganizer($0)
        }
    }

    // MARK: - Open flows

    private func openSigning(_ url: URL) {
        guard let wc = SigningWindowController(pdfURL: url) else {
            infoAlert("Couldn’t open PDF", "“\(url.lastPathComponent)” couldn’t be read as a PDF.")
            return
        }
        wc.onCancel = { [weak self, weak wc] in wc?.close(); self?.showPopover() }
        AppDelegate.signers.append(wc)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openOrganizer(_ urls: [URL]) {
        let pages = loadPages(from: urls)
        guard !pages.isEmpty else {
            infoAlert("Nothing to organize", "None of the selected files could be read as PDFs or images.")
            return
        }
        let wc = PageOrganizerWindowController(pages: pages)
        wc.onCancel = { [weak self, weak wc] in wc?.close(); self?.showPopover() }
        AppDelegate.organizers.append(wc)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Image → PDF

    private func makeImagePDF(_ urls: [URL]) {
        let images = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let pdf = PDFDocument()
        var n = 0
        var skipped: [String] = []
        for url in images {
            if let img = downscaleImage(url), let page = PDFPage(image: img) {
                pdf.insert(page, at: n); n += 1
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        guard n > 0 else {
            infoAlert("Couldn’t read those images", "None of the selected files could be processed.")
            return
        }
        let out = desktopURL(name: "Jack_\(timestamp()).pdf")
        if pdf.write(to: out) {
            NSWorkspace.shared.activateFileViewerSelecting([out])
            NSSound(named: "Glass")?.play()
            if !skipped.isEmpty {
                infoAlert("PDF created", "Saved \(n) page(s) to \(out.lastPathComponent) on your Desktop.\n\nSkipped (unreadable): \(skipped.joined(separator: ", "))")
            }
        } else {
            infoAlert("Save failed", "Couldn’t write the PDF to your Desktop.")
        }
    }
}

func timestamp() -> String {
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HHmmss"; return df.string(from: Date())
}

func desktopURL(name: String) -> URL {
    let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    return desktop.appendingPathComponent(name)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
