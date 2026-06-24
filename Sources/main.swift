// Jack — a lightweight PDF utility: combine photos, sign, and organize pages.
// ThinkOpen Inc.
import Cocoa
import ImageIO
import PDFKit
import UniformTypeIdentifiers

let MAX_EDGE: CGFloat = 1600
let JPEG_QUALITY: CGFloat = 0.72

// Shared, simple info alert used across the app.
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

// Downscale an image to MAX_EDGE on the long edge (never upscales), honoring EXIF orientation.
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

// Load detached PDFPages from a list of PDFs and/or images, in the given order.
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
    private var home: HomeWindowController?
    static var signers: [SigningWindowController] = []
    static var organizers: [PageOrganizerWindowController] = []

    // Drop files on the app icon / "Open With… Jack". Coalesce rapid split open calls.
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, !self.didHandleOpen else { return }
            self.showHome()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Drag-drop intent heuristics: photos→combine, one PDF→sign, multiple/mixed→organize.
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
            showHome()
        }
    }

    // MARK: - Home

    private func showHome() {
        if home == nil {
            let h = HomeWindowController()
            h.onPhotos = { [weak self] in self?.pickPhotos() }
            h.onSign = { [weak self] in self?.pickSign() }
            h.onOrganize = { [weak self] in self?.pickOrganize() }
            h.onDrop = { [weak self] urls in self?.route(urls) }
            home = h
        }
        home?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Pickers (explicit actions never auto-quit; the home window keeps the app alive)

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
        wc.onCancel = { [weak self, weak wc] in
            self?.showHome()
            wc?.close()
        }
        AppDelegate.organizers.append(wc)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Image → PDF (the original droplet behavior)

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
            quitIfNoWindows(); return
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.quitIfNoWindows() }
    }

    // Quit only on the windowless drag-drop combine path; stay alive if any window is open.
    private func quitIfNoWindows() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if !hasWindow { NSApp.terminate(nil) }
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
app.setActivationPolicy(.regular)
app.run()
