// Jack — drop photos to get one resized PDF, or open a PDF to sign it.
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didHandleOpen = false
    private var pending: [URL] = []
    private var scheduled = false
    static var windows: [SigningWindowController] = []

    // Drop files on the app icon / "Open With… Jack".
    // Coalesce rapid open calls (the OS sometimes splits a multi-file drop) into one batch.
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
            self.showOpenPanel()
        }
    }

    // Quit once the last signing window closes (the image flow has no window and quits itself).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func route(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        let images = urls.filter(isImage)
        if !pdfs.isEmpty {
            pdfs.forEach(openSigning)
        } else if !images.isEmpty {
            makeImagePDF(images)
        } else {
            showOpenPanel()
        }
    }

    // The Open panel runs out-of-process, so its button can't be re-labeled mid-selection.
    // Ask up front which action, then open the right panel with the correct button text.
    private func showOpenPanel() {
        let a = NSAlert()
        a.messageText = "What would you like to do?"
        a.informativeText = "Sign a PDF, or combine photos into one PDF."
        a.addButton(withTitle: "Sign a PDF…")
        a.addButton(withTitle: "Combine Photos…")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: pickFiles(forPhotos: false)
        case .alertSecondButtonReturn: pickFiles(forPhotos: true)
        default: NSApp.terminate(nil)
        }
    }

    private func pickFiles(forPhotos: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = forPhotos
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = forPhotos ? "Choose photos to combine into one PDF" : "Choose a PDF to sign"
        panel.prompt = forPhotos ? "Make PDF" : "Open"
        if #available(macOS 11.0, *) { panel.allowedContentTypes = forPhotos ? [.image] : [.pdf] }
        if panel.runModal() == .OK { route(panel.urls) } else { NSApp.terminate(nil) }
    }

    private func openSigning(_ url: URL) {
        guard let wc = SigningWindowController(pdfURL: url) else {
            infoAlert("Couldn’t open PDF", "“\(url.lastPathComponent)” couldn’t be read as a PDF.")
            return
        }
        AppDelegate.windows.append(wc)
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
            if let img = downscaled(url: url), let page = PDFPage(image: img) {
                pdf.insert(page, at: n); n += 1
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        guard n > 0 else {
            infoAlert("Couldn’t read those images", "None of the dropped files could be processed.")
            NSApp.terminate(nil); return
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }

    func isImage(_ url: URL) -> Bool {
        if #available(macOS 11.0, *),
           let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp"]
        return exts.contains(url.pathExtension.lowercased())
    }

    private func downscaled(url: URL) -> NSImage? {
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
