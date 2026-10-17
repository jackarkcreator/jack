// Jack — a lightweight PDF utility that lives in the menu bar: combine photos, fill & sign, organize.
// ThinkOpen Inc.
import Cocoa
import ImageIO
import PDFKit
import ServiceManagement
import Sparkle
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var didHandleOpen = false
    private var pending: [URL] = []
    private var scheduled = false
    static var organizers: [PageOrganizerWindowController] = []
    static var documents: [DocumentWindowController] = []
    static var batchers: [BatchWindowController] = []

    // Menu bar accessory until the first document opens — then a real Dock/⌘-Tab app for the
    // rest of the session (Preview-like; vanishing from ⌘-Tab on close read as broken).
    static func updateActivationPolicy() {
        let openDocs = documents.count + organizers.count + batchers.count
        if openDocs > 0 && NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var statusItem: NSStatusItem!
    private var dropShelf: DropShelf?
    private let popover = NSPopover()
    private let popoverVC = HomePopoverViewController()
    // Sparkle: auto-checks daily per SUScheduledCheckInterval; downloads, installs, relaunches.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    // Drop files on the menu bar icon / "Open With… Jack". Coalesce split open calls.
    func application(_ application: NSApplication, open urls: [URL]) {
        didHandleOpen = true
        // jack://convert?p=<base64 path>&p=… — the sandboxed Finder extension can't touch
        // files, so it ferries the selection over the URL scheme and the app does the work.
        var files: [URL] = []
        for u in urls {
            if u.scheme == "jack", u.host == "convert" {
                let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
                for q in comps?.queryItems ?? [] where q.name == "p" {
                    if let v = q.value, let data = Data(base64Encoded: v),
                       let path = String(data: data, encoding: .utf8) {
                        files.append(URL(fileURLWithPath: path))
                    }
                }
            } else {
                files.append(u)
            }
        }
        pending.append(contentsOf: files)
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            let batch = self.pending; self.pending = []; self.scheduled = false
            self.route(batch)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // v2.5: autosave-in-place is off, so a crash would otherwise lose the session's edits.
        // Autosave-elsewhere writes a scratch copy under ~/Library/Autosave Information and
        // NEVER the user's original; macOS offers it back on the next launch.
        NSDocumentController.shared.autosavingDelay = 30
        setupStatusItem()
        setupPopover()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        // The Drop Shelf: a corner target that exists only while a file drag is in flight.
        dropShelf = DropShelf(onDrop: { [weak self] urls in self?.route(urls) })
        configureLoginOnFirstRun()
        enforceDefaultIfWanted()
        MainMenu.install(newAction: #selector(newDocumentAction),
                         openAction: #selector(openDocumentAction),
                         defaultAction: #selector(makeDefaultAction),
                         updateAction: #selector(checkUpdatesAction),
                         target: self)
        runWindowShowcaseIfRequested()
        checkForUpdate()
        // Dev-only test hook: `Jack --organize a.pdf b.pdf` opens the organizer directly.
        if let flag = CommandLine.arguments.firstIndex(of: "--organize"),
           !Bundle.main.bundlePath.hasPrefix("/Applications") {
            let files = CommandLine.arguments.dropFirst(flag + 1).map { URL(fileURLWithPath: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openOrganizer(files)
            }
            return
        }
        // Dev/CLI launches pass files as argv; AppKit only auto-delivers SOME types that
        // way (PDF yes, docx no — probed). LaunchServices launches use open-urls, so this
        // fallback fires only when nothing was delivered.
        let argvFiles = CommandLine.arguments.dropFirst()
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !argvFiles.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.didHandleOpen else { return }
                self.didHandleOpen = true
                self.route(Array(argvFiles))
            }
        }
        // Show the launcher ONCE on the very first launch (discoverability) — never again.
        // After that, the menu bar icon is the way in.
        let shownKey = "jack.launcherShown"
        if !UserDefaults.standard.bool(forKey: shownKey) {
            UserDefaults.standard.set(true, forKey: shownKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, !self.didHandleOpen else { return }
                self.showPopover()
            }
        }
    }

    // Stay resident in the menu bar after document windows close.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Launching or re-activating Jack must never spawn a blank Untitled document —
    // ⌘N is the only way to ask for one. Activating with nothing open shows the launcher.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showPopover() }
        return false
    }

    private func route(_ urls: [URL]) {
        // A dropped FOLDER means batch processing.
        if let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }) {
            openBatch(folder)
            return
        }
        // Word/RTF/text convert to PDF (JC's ask); spreadsheets get the honest refusal.
        let convertibles = urls.filter(ConvertEngine.isConvertible)
        let refused = urls.filter(ConvertEngine.isRefused)
        if !convertibles.isEmpty || !refused.isEmpty {
            convertFiles(convertibles, refused: refused)
            let rest = urls.filter { !ConvertEngine.isConvertible($0) && !ConvertEngine.isRefused($0) }
            if rest.isEmpty { return }
            route(rest)
            return
        }
        let pdfs = urls.filter(isPDFURL)
        let images = urls.filter(isImageURL)
        if pdfs.count == 1 && images.isEmpty {
            openDocument(pdfs[0])
        } else if !pdfs.isEmpty {
            openOrganizer(urls)
        } else if !images.isEmpty {
            makeImagePDF(images)
        } else {
            showPopover()
        }
    }

    /// Convert each source beside itself; a single result opens straight in Jack,
    /// several get revealed in Finder. Failures are reported plainly, never silently.
    private func convertFiles(_ sources: [URL], refused: [URL]) {
        for r in refused {
            infoAlert("Can\u{2019}t convert \(r.lastPathComponent)",
                      ConvertEngine.ConvertError.unsupported(r.pathExtension.lowercased()).localizedDescription)
        }
        var outputs: [URL] = []
        var failures: [String] = []
        for src in sources {
            do { outputs.append(try ConvertEngine.convertToPDF(src)) }
            catch { failures.append("\(src.lastPathComponent) — \(error.localizedDescription)") }
        }
        if !failures.isEmpty {
            infoAlert("Some files couldn\u{2019}t be converted", failures.joined(separator: "\n"))
        }
        if outputs.count == 1 {
            openDocument(outputs[0])
        } else if !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
    }

    // Finder right-click → Services → "Convert to PDF with Jack".
    @objc func convertService(_ pboard: NSPasteboard, userData: String,
                              error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.route(urls) }
    }

    // MARK: - Menu bar item & popover

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        // v3: Paper Jack in the menu bar (template glyph matching the app icon).
        if let img = Optional(Chrome.menuBarGlyph()) {
            // Dev builds (anything not running from /Applications) wear AMBER in the menu
            // bar, so a dev instance can never masquerade as the real Jack again.
            if Bundle.main.bundlePath.hasPrefix("/Applications") {
                img.isTemplate = true
                button.image = img
            } else {
                let size = img.size
                let tinted = NSImage(size: size, flipped: false) { rect in
                    img.draw(in: rect)
                    NSColor(calibratedRed: 0.96, green: 0.65, blue: 0.14, alpha: 1).set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.isTemplate = false
                button.image = tinted
                button.toolTip = "Jack (dev build)"
            }
        }
        let overlay = StatusDropView(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClick = { [weak self] in self?.togglePopover() }
        overlay.onDrop = { [weak self] urls in self?.popover.performClose(nil); self?.route(urls) }
        overlay.onDragHover = { [weak self] in self?.showPopover(activating: false) }
        button.addSubview(overlay)
    }

    private func setupPopover() {
        popoverVC.onNew = { [weak self] in self?.popover.performClose(nil); self?.newDocumentAction() }
        popoverVC.onOpen = { [weak self] in self?.popover.performClose(nil); self?.pickOpen() }
        popoverVC.onMakeDefault = { [weak self] in self?.popover.performClose(nil); self?.makeDefaultPDFApp() }
        popoverVC.onPhotos = { [weak self] in self?.popover.performClose(nil); self?.pickPhotos() }
        popoverVC.onSign = { [weak self] in self?.popover.performClose(nil); self?.pickSign() }
        popoverVC.onOrganize = { [weak self] in self?.popover.performClose(nil); self?.pickOrganize() }
        popoverVC.onBatch = { [weak self] in self?.popover.performClose(nil); self?.pickBatchFolder() }
        popoverVC.onFilesDropped = { [weak self] urls in self?.popover.performClose(nil); self?.route(urls) }
        popoverVC.onQuit = { NSApp.terminate(nil) }
        popoverVC.onUpdate = { [weak self] in self?.popover.performClose(nil); self?.updater.checkForUpdates(nil) }
        popoverVC.onToggleLogin = { [weak self] on in self?.setLogin(on) }
        popoverVC.onToggleShelf = { [weak self] on in
            UserDefaults.standard.set(on, forKey: DropShelf.prefKey)
            if !on { self?.dropShelf?.hide() }
        }
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.delegate = self
    }

    // 3.1: close on ANY click outside the launcher. `.transient` alone relies on Jack being the
    // active app, which a menu-bar app often isn't (macOS 14+ cooperative activation), so a
    // click on the desktop or another app left the launcher open. Monitors live only while
    // the launcher is shown.
    private var outsideClickMonitors: [Any] = []
    func popoverWillShow(_ notification: Notification) { installOutsideClickMonitors() }
    /// Installed the moment the launcher opens (not after its animation), so an early click counts.
    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            self?.popover.performClose(nil)
        }) { outsideClickMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            guard let self else { return e }
            let inLauncher = e.window === self.popoverVC.view.window
            let onIcon = e.window === self.statusItem.button?.window   // the icon toggles it itself
            EventLog.note("launcher local monitor: type=\(e.type.rawValue) window=\(e.window.map { String(describing: type(of: $0)) } ?? "nil") inLauncher=\(inLauncher) onIcon=\(onIcon)")
            if !inLauncher && !onIcon {
                self.popover.performClose(nil)
                EventLog.note("launcher performClose -> isShown=\(self.popover.isShown)")
            }
            return e
        }) { outsideClickMonitors.append(l) }
    }
    func popoverDidClose(_ notification: Notification) { removeOutsideClickMonitors() }
    private func removeOutsideClickMonitors() {
        outsideClickMonitors.forEach(NSEvent.removeMonitor)
        outsideClickMonitors.removeAll()
    }
    /// Verification hook: whether the outside-click monitors are installed right now.
    var launcherWatchesOutsideClicks: Bool { !outsideClickMonitors.isEmpty }

    // MARK: - Window showcase (verification only)

    /// JACK_SHOWCASE_WINDOW=<organizer|batch|settings|launcher> opens that window parked BEHIND
    /// other apps (never activated, no input), writes its window number to
    /// /tmp/jack-showcase.id for a window-scoped screencapture, and quits after 8 s.
    /// JACK_SHOWCASE_PDF names the fixture; JACK_MODE_SELFTEST_APPEARANCE=light|dark forces the look.
    private static var showcaseKeep: [AnyObject] = []
    private func runWindowShowcaseIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let which = env["JACK_SHOWCASE_WINDOW"] else { return }
        if let ap = env["JACK_MODE_SELFTEST_APPEARANCE"] { NSApp.appearance = NSAppearance(named: ap == "light" ? .aqua : .darkAqua) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            var win: NSWindow?
            let pdfURL = URL(fileURLWithPath: env["JACK_SHOWCASE_PDF"] ?? "")
            switch which {
            case "organizer", "organizerfull":
                if let doc = PDFDocument(url: pdfURL) {
                    Self.showcaseKeep.append(doc)
                    let pages = (0..<doc.pageCount).compactMap { doc.page(at: $0) }
                    let wc = PageOrganizerWindowController(groups: [PageGroup(name: pdfURL.deletingPathExtension().lastPathComponent, pages: pages)])
                    Self.showcaseKeep.append(wc)
                    win = wc.window
                    if which == "organizerfull" { _ = wc.perform(NSSelectorFromString("addAll")) }
                }
            case "batch":
                let wc = BatchWindowController(folder: pdfURL.deletingLastPathComponent())
                Self.showcaseKeep.append(wc)
                win = wc.window
            case "settings":
                win = SettingsWindowController.shared.window
            case "launcher", "launcherclose":
                self.showPopover(activating: false)
                win = self.popoverVC.view.window
                if which == "launcherclose" {
                    // A click in another Jack window must close the launcher (local monitor path).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        let watching = self.launcherWatchesOutsideClicks, shownBefore = self.popover.isShown
                        let other = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
                        other.orderFrontRegardless()
                        if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: other.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            EventLog.note("probe: posting mouseDown to window \(other.windowNumber)")
                            NSApp.postEvent(e, atStart: false)   // through the queue, like a real click
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let info = "watching=\(watching) shownBefore=\(shownBefore) shownAfterOutsideClick=\(self.popover.isShown) watchingAfter=\(self.launcherWatchesOutsideClicks)"
                            try? info.write(toFile: "/tmp/jack-showcase.info", atomically: true, encoding: .utf8)
                            other.orderOut(nil)
                        }
                    }
                }
            default: break
            }
            if which != "launcher" { win?.orderBack(nil) }   // organizer/organizerfull/batch/settings
            if let win { try? "\(win.windowNumber)".write(toFile: "/tmp/jack-showcase.id", atomically: true, encoding: .utf8) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
        }
    }

    private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover(activating: Bool = true) {
        guard let button = statusItem.button else { return }
        if popover.isShown { return }
        popoverVC.loginEnabled = isLoginEnabled()
        popoverVC.shelfEnabled = DropShelf.enabled
        popoverVC.defaultEnabled = AppDelegate.isDefaultPDFApp()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if outsideClickMonitors.isEmpty { installOutsideClickMonitors() }
        // Spring-loaded opens (mid-drag) must not steal focus from the drag source.
        if activating { NSApp.activate(ignoringOtherApps: true) }
        checkForUpdate()
    }

    private func checkForUpdate() {
        UpdateChecker.check { [weak self] info in
            guard let self = self, let info = info else { return }
            self.popoverVC.showUpdate(version: info.version, url: info.url)
        }
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
    private func pickOpen() {
        runPicker(.pdf, multi: false, message: "Choose a PDF to open", prompt: "Open") {
            [weak self] in self?.route($0)
        }
    }
    private func pickSign() {
        runPicker(.pdf, multi: false, message: "Choose a PDF to fill or sign", prompt: "Open") {
            [weak self] in if let u = $0.first { self?.openDocument(u, markup: true) }
        }
    }
    private func pickBatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose a folder of PDFs to process"
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { openBatch(url) }
    }

    private func openBatch(_ folder: URL) {
        let wc = BatchWindowController(folder: folder)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pickOrganize() {
        runPicker(.both, multi: true, message: "Choose PDFs and photos to combine, reorder, or extract pages", prompt: "Open") {
            [weak self] in self?.openOrganizer($0)
        }
    }

    // MARK: - Menu actions

    @objc func newDocumentAction() {
        // The document presents its own window (never trust display:true with
        // hand-built window controllers).
        try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
    }

    @objc private func openDocumentAction() {
        runPicker(.both, multi: true, message: "Choose PDFs or photos to open", prompt: "Open") {
            [weak self] in self?.route($0)
        }
    }

    @objc private func makeDefaultAction() { makeDefaultPDFApp() }

    // Set once, stays forever: remember the choice and silently re-claim on every launch,
    // so reinstalls/updates can never quietly hand PDFs back to Preview.
    static let wantsDefaultKey = "jack.wantsDefault"

    static func isDefaultPDFApp() -> Bool {
        guard let h = LSCopyDefaultRoleHandlerForContentType("com.adobe.pdf" as CFString, .all)?
            .takeRetainedValue() as String? else { return false }
        return h.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "") == .orderedSame
    }

    @discardableResult
    static func claimDefaultSilently() -> Bool {
        let bid = (Bundle.main.bundleIdentifier ?? "net.thinkopen.jack") as CFString
        LSSetDefaultRoleHandlerForContentType("com.adobe.pdf" as CFString, .all, bid)
        return isDefaultPDFApp()
    }

    func enforceDefaultIfWanted() {
        guard UserDefaults.standard.bool(forKey: AppDelegate.wantsDefaultKey),
              !AppDelegate.isDefaultPDFApp() else { return }
        AppDelegate.claimDefaultSilently()
    }

    private func makeDefaultPDFApp() {
        UserDefaults.standard.set(true, forKey: AppDelegate.wantsDefaultKey)
        if AppDelegate.claimDefaultSilently() {
            popoverVC.defaultEnabled = true
            infoAlert("Jack is your PDF app", "Double-clicking any PDF now opens it in Jack — and it stays that way, even across updates.")
            return
        }
        // Silent claim refused (hardened LS) — fall back to the system-mediated request.
        if #available(macOS 12.0, *) {
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .pdf) { error in
                DispatchQueue.main.async {
                    if let error = error {
                        infoAlert("Couldn’t set default", error.localizedDescription)
                    } else {
                        infoAlert("Jack is your PDF app", "Double-clicking any PDF now opens it in Jack — and it stays that way, even across updates.")
                    }
                }
            }
        } else {
            infoAlert("Set Jack as default", "Right-click any PDF → Get Info → Open With → Jack → Change All…")
        }
    }

    @objc private func checkUpdatesAction() {
        updater.checkForUpdates(nil)
    }

    // MARK: - Open flows

    private func openDocument(_ url: URL, markup: Bool = false) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
            if let error = error {
                infoAlert("Couldn’t open PDF", error.localizedDescription)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            if markup, let wc = (doc as? JackDocument)?.windowControllers.first as? DocumentWindowController {
                wc.openInMarkup()
            }
        }
    }

    private func openOrganizer(_ urls: [URL]) {
        // One labeled pile per document; runs of photos share a "Photos" pile.
        var pageGroups: [PageGroup] = []
        var photoRun: [PDFPage] = []
        func flushPhotos() {
            guard !photoRun.isEmpty else { return }
            pageGroups.append(PageGroup(name: photoRun.count == 1 ? "Photo" : "Photos", pages: photoRun))
            photoRun = []
        }
        for url in urls {
            let pages = loadPages(from: [url])
            guard !pages.isEmpty else { continue }
            if isPDFURL(url) {
                flushPhotos()
                pageGroups.append(PageGroup(name: url.deletingPathExtension().lastPathComponent, pages: pages))
            } else {
                photoRun.append(contentsOf: pages)
            }
        }
        flushPhotos()
        guard !pageGroups.isEmpty else {
            infoAlert("Nothing to organize", "None of the selected files could be read as PDFs or images.")
            return
        }
        let wc = PageOrganizerWindowController(groups: pageGroups)
        wc.onCancel = { [weak self, weak wc] in wc?.close(); self?.showPopover() }
        AppDelegate.organizers.append(wc)
        AppDelegate.updateActivationPolicy()
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
