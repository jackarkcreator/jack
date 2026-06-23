// Jack — drop photos, get one resized PDF.
// ThinkOpen Inc. Replaces the legacy "Photo Resize" + "PDF Creator" Automator droplets.
import Cocoa
import ImageIO
import PDFKit
import UniformTypeIdentifiers

let MAX_EDGE: CGFloat = 1600     // long-edge cap in pixels
let JPEG_QUALITY: CGFloat = 0.72 // re-encode quality for the embedded pages

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didHandleOpen = false

    // Fired when the user drops files on the app icon (or "Open With… Jack").
    func application(_ application: NSApplication, open urls: [URL]) {
        didHandleOpen = true
        process(urls: urls)
    }

    // Double-clicked with no files → fall back to a picker so the app is still usable.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, !self.didHandleOpen else { return }
            self.pickAndProcess()
        }
    }

    private func pickAndProcess() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose photos to combine into one PDF"
        panel.prompt = "Make PDF"
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.image] }
        else { panel.allowedFileTypes = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp"] }
        if panel.runModal() == .OK { process(urls: panel.urls) } else { NSApp.terminate(nil) }
    }

    private func process(urls: [URL]) {
        let images = urls
            .filter(isImage)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !images.isEmpty else {
            alert("No images found",
                  "Drop photos (JPEG, PNG, HEIC…) onto Jack and it will resize them and build one PDF.")
            NSApp.terminate(nil); return
        }

        let pdf = PDFDocument()
        var pageCount = 0
        var skipped: [String] = []

        for url in images {
            if let img = downscaled(url: url), let page = PDFPage(image: img) {
                pdf.insert(page, at: pageCount)
                pageCount += 1
            } else {
                skipped.append(url.lastPathComponent)
            }
        }

        guard pageCount > 0 else {
            alert("Couldn’t read those images", "None of the dropped files could be processed.")
            NSApp.terminate(nil); return
        }

        let out = desktopOutput()
        if pdf.write(to: out) {
            NSWorkspace.shared.activateFileViewerSelecting([out])
            NSSound(named: "Glass")?.play()
            if !skipped.isEmpty {
                alert("PDF created",
                      "Saved \(pageCount) page(s) to \(out.lastPathComponent) on your Desktop.\n\nSkipped (unreadable): \(skipped.joined(separator: ", "))")
            }
        } else {
            alert("Save failed",
                  "Couldn’t write the PDF to your Desktop. If macOS asked for Desktop access, allow it and try again.")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }

    // MARK: - Helpers

    private func isImage(_ url: URL) -> Bool {
        if #available(macOS 11.0, *),
           let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp"]
        return exts.contains(url.pathExtension.lowercased())
    }

    // Downscale to MAX_EDGE (never upscales), honoring EXIF orientation, then re-encode as JPEG to shrink.
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

    private func desktopOutput() -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        return desktop.appendingPathComponent("Jack_\(df.string(from: Date())).pdf")
    }

    private func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .informational
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
