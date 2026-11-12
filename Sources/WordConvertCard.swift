// Convert to Word without opening a window (3.5, ratified mock decisions C1–C7, Luis 2026-11-11:
// https://claude.ai/artifact/2wXnJg4C8GjD4U5wEp9Mvy).
//
// A small card in the corner of the screen runs Save as Word with the 3.4 defaults (C3: Match
// pages, keep the letterhead, highlight words to double-check) for PDFs that arrive from the
// Drop Shelf, the menu-bar icon or Finder's right-click. No PDF window opens (C2); the card ends
// on Open in Word / Show in Finder, or an honest refusal with Copy Text (C4). Several PDFs share
// one card with a row per file, converted one after another (C7).
//
// The card is a non-activating panel: the app the user is working in keeps the keyboard.
import AppKit
import PDFKit

final class WordConvertCard: NSObject {
    static let shared = WordConvertCard()
    /// Opens a PDF in Jack; `true` also shows the full Save as Word sheet (Options…). Set by AppDelegate.
    static var openInJack: ((URL, Bool) -> Void)?

    final class Job {
        enum State { case waiting, working, done, refused, failed, stopped }
        let source: URL
        var state = State.waiting
        var pages = 0
        var scanned = 0
        var page = 0
        var started: Date?
        var output: URL?
        var report: WordExportEngine.Report?
        var message = ""            // refusal reason or failure, in plain words
        var text = ""               // every word read, for Copy Text on a refusal
        var savedElsewhere = false  // the PDF's folder was read-only: saved to the Desktop
        init(source: URL) { self.source = source }
        var name: String { source.lastPathComponent }
        var finished: Bool { state != .waiting && state != .working }
    }

    private(set) var jobs: [Job] = []
    private var panel: CardPanel?
    private var running = false
    private let lock = NSLock()
    private var stopFlag = false
    private var closeTimer: Timer?
    private var anchorScreen: NSScreen?
    /// Self-test hook: every render reports a one-line summary of the card.
    var onRender: ((String) -> Void)?

    // MARK: Queue

    func convert(_ urls: [URL]) {
        let pdfs = urls.filter(isPDFURL)
        guard !pdfs.isEmpty else { return }
        if !running { jobs.removeAll(); anchorScreen = nil }   // a finished card makes way for the new batch
        for u in pdfs where !jobs.contains(where: { $0.source == u && !$0.finished }) {
            jobs.append(Job(source: u))
        }
        closeTimer?.invalidate()
        render()
        startNext()
    }

    func stopAll() {
        lock.lock(); stopFlag = true; lock.unlock()
        for j in jobs where j.state == .waiting { j.state = .stopped }
        render()
    }

    private var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopFlag }

    private func startNext() {
        guard !running else { return }
        guard let job = jobs.first(where: { $0.state == .waiting }) else { allFinished(); return }
        running = true
        lock.lock(); stopFlag = false; lock.unlock()
        job.state = .working
        job.started = Date()
        render()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let apply = self.work(job)
            DispatchQueue.main.async {
                apply()
                self.running = false
                self.render()
                self.startNext()
            }
        }
    }

    /// Runs on a background queue; returns the main-thread update for the job's outcome.
    private func work(_ job: Job) -> () -> Void {
        let src = job.source
        // PDFKit isn't thread-safe: this queue owns its own copy of the file.
        guard let doc = PDFDocument(url: src), doc.pageCount > 0 else {
            return { job.state = .failed; job.message = "Jack couldn\u{2019}t read this PDF." }
        }
        if doc.isLocked {
            return { job.state = .failed; job.message = "This PDF is locked with a password. Open it in Jack to unlock it first." }
        }
        var scans = 0
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            let text = (p.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count <= 20 || WordExportEngine.isScanPage(p) { scans += 1 }
        }
        let total = doc.pageCount
        DispatchQueue.main.async { [weak self] in job.pages = total; job.scanned = scans; self?.render() }

        var out = WordExportEngine.outputURL(for: src)
        var elsewhere = false
        if !FileManager.default.isWritableFile(atPath: src.deletingLastPathComponent().path) {
            out = WordExportEngine.outputURL(for: desktopURL(name: src.lastPathComponent))
            elsewhere = true
        }
        let title = src.deletingPathExtension().lastPathComponent
        do {
            let r = try WordExportEngine.export(doc, to: out, title: title, options: WordExportEngine.Options(),
                progress: { i, n in
                    DispatchQueue.main.async { [weak self] in job.page = i; self?.render() }
                }, cancelled: { [weak self] in self?.isStopping ?? true })
            if isStopping {   // stopped after the file was already written: honour the Stop
                try? FileManager.default.removeItem(at: out)
                return { job.state = .stopped }
            }
            return { job.state = .done; job.output = out; job.report = r; job.savedElsewhere = elsewhere }
        } catch WordExportEngine.ExportError.refused(let why, let text) {
            try? FileManager.default.removeItem(at: out)
            return { job.state = .refused; job.message = why; job.text = text }
        } catch WordExportEngine.ExportError.cancelled {
            try? FileManager.default.removeItem(at: out)
            return { job.state = .stopped }
        } catch {
            try? FileManager.default.removeItem(at: out)
            let msg = error.localizedDescription
            return { job.state = .failed; job.message = msg }
        }
    }

    private func allFinished() {
        render()
        guard !jobs.isEmpty else { return }
        if jobs.contains(where: { $0.state == .done }) { NSSound(named: "Glass")?.play() }
        // Everything stopped: nothing to look at, so the card goes away on its own quickly.
        let delay: TimeInterval = jobs.allSatisfy({ $0.state == .stopped }) ? 2.5 : 60
        scheduleClose(after: delay)
    }

    private func scheduleClose(after delay: TimeInterval) {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            // Never pull the card away from under the pointer.
            if NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) { self.scheduleClose(after: 10); return }
            self.close()
        }
    }

    func close() {
        guard !running else { return }
        closeTimer?.invalidate()
        panel?.orderOut(nil)
        jobs.removeAll()
        anchorScreen = nil
    }

    // MARK: Actions

    @objc private func stopPressed(_ sender: Any?) { stopAll() }
    @objc private func closePressed(_ sender: Any?) { close() }
    @objc private func openWordPressed(_ sender: NSButton) {
        guard let j = job(for: sender), let out = j.output else { return }
        NSWorkspace.shared.open(out)
        close()
    }
    @objc private func showInFinderPressed(_ sender: Any?) {
        let outs = jobs.compactMap { $0.output }
        if !outs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outs) }
    }
    @objc private func copyTextPressed(_ sender: NSButton) {
        guard let j = job(for: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(j.text, forType: .string)
        close()
    }
    @objc private func openInJackPressed(_ sender: NSButton) {
        guard let j = job(for: sender) else { return }
        close()
        Self.openInJack?(j.source, false)
    }
    @objc private func optionsPressed(_ sender: NSButton) {
        guard let j = job(for: sender) else { return }
        close()
        Self.openInJack?(j.source, true)
    }
    private func job(for sender: NSButton) -> Job? {
        jobs.indices.contains(sender.tag) ? jobs[sender.tag] : nil
    }

    // MARK: Rendering

    private let accent = NSColor(calibratedRed: 0.055, green: 0.431, blue: 0.431, alpha: 1)

    private func render() {
        guard !jobs.isEmpty else { return }
        let single = jobs.count == 1
        let width: CGFloat = single ? 352 : 380
        let content = single ? singleView(jobs[0], width: width) : listView(width: width)
        onRender?(summaryLine())

        let p = panel ?? makePanel()
        let frost = p.contentView as! CardView
        frost.subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        frost.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: frost.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: frost.trailingAnchor),
            content.topAnchor.constraint(equalTo: frost.topAnchor),
            content.widthAnchor.constraint(equalToConstant: width),
        ])
        if !running && jobs.allSatisfy({ $0.finished }) {
            let x = FirstMouseButton(image: Chrome.symbol(["xmark"], "Close", NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)) ?? NSImage(),
                                     target: self, action: #selector(closePressed(_:)))
            x.isBordered = false
            x.contentTintColor = .secondaryLabelColor
            x.setAccessibilityLabel("Close")
            x.translatesAutoresizingMaskIntoConstraints = false
            frost.addSubview(x)
            NSLayoutConstraint.activate([x.topAnchor.constraint(equalTo: frost.topAnchor, constant: 10),
                                         x.trailingAnchor.constraint(equalTo: frost.trailingAnchor, constant: -12),
                                         x.widthAnchor.constraint(equalToConstant: 16), x.heightAnchor.constraint(equalToConstant: 16)])
        }
        frost.layoutSubtreeIfNeeded()
        let h = ceil(content.fittingSize.height)
        // Bottom-right of the screen the card first appeared on (22 pt in, like the Drop Shelf).
        if anchorScreen == nil {
            anchorScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        }
        if let vf = anchorScreen?.visibleFrame {
            p.setFrame(NSRect(x: vf.maxX - width - 22, y: vf.minY + 22, width: width, height: h), display: true)
        }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    private func makePanel() -> CardPanel {
        let p = CardPanel(contentRect: NSRect(x: 0, y: 0, width: 352, height: 160),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .aqua)   // the Drop Shelf's light frost, everywhere
        let frost = CardView()
        frost.material = .popover
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.wantsLayer = true
        frost.layer?.cornerRadius = 16
        frost.layer?.masksToBounds = true
        frost.layer?.borderWidth = 0.5
        frost.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        frost.onEscape = { [weak self] in self?.running == true ? self?.stopAll() : self?.close() }
        p.contentView = frost
        panel = p
        return p
    }

    private func summaryLine() -> String {
        jobs.map { j in
            var s = "\(j.name)=\(j.state)"
            if j.state == .working { s += "(\(j.page)/\(j.pages))" }
            if let o = j.output { s += "->\(o.lastPathComponent)" }
            if !j.message.isEmpty { s += " [\(j.message)]" }
            return s
        }.joined(separator: " | ")
    }

    // One PDF: the mock's boards 2 and 3.
    private func singleView(_ j: Job, width: CGFloat) -> NSView {
        let inner = width - 32
        var rows: [NSView] = []
        let pagesText = j.pages == 0 ? "" : " \u{00B7} \(j.pages) page\(j.pages == 1 ? "" : "s")"
            + (j.scanned == 0 ? "" : j.scanned == j.pages ? ", scanned" : ", \(j.scanned) scanned")
        switch j.state {
        case .waiting, .working:
            rows.append(header(.word, "Converting to Word", j.name + pagesText, inner))
            let bar = progressBar(j)
            rows.append(bar)
            let status = small(statusText(j), .secondaryLabelColor)
            let eta = small(etaText(j), .secondaryLabelColor)
            rows.append(hstack([status, NSView(), eta], spacing: 6))
            let note = small("On this Mac \u{00B7} Match pages \u{00B7} highlights on", .secondaryLabelColor)
            let stop = button("Stop", #selector(stopPressed(_:)), tag: 0)
            rows.append(hstack([icon("lock", .secondaryLabelColor), note, NSView(), stop], spacing: 7))
        case .done:
            let where_ = j.savedElsewhere ? "on your Desktop" : "in " + j.source.deletingLastPathComponent().lastPathComponent
            rows.append(header(.check, "Saved as Word", "\(j.output?.lastPathComponent ?? "") \u{00B7} \(where_)", inner))
            if let r = j.report {
                if let m = r.missingPages {
                    rows.append(wrap("Pages \(m.lowerBound)\u{2013}\(m.upperBound) aren\u{2019}t in this PDF (the footers say \(m.upperBound)). Get them before relying on it.", .systemOrange, inner))
                }
                if j.savedElsewhere {
                    rows.append(wrap("The PDF\u{2019}s folder can\u{2019}t be written to, so the Word file went to your Desktop.", .secondaryLabelColor, inner))
                }
                if r.uncertainWords > 0 {
                    rows.append(hstack([swatch(), small("\(r.uncertainWords) word\(r.uncertainWords == 1 ? "" : "s") to double-check, highlighted in Word", .labelColor)], spacing: 8))
                } else {
                    rows.append(hstack([icon("checkmark.circle", accent), small("Every word matched a second reading", .labelColor)], spacing: 8))
                }
                if r.signaturePlaceholders > 0 {
                    rows.append(hstack([icon("signature", .secondaryLabelColor),
                                        small("\(r.signaturePlaceholders) signature\(r.signaturePlaceholders == 1 ? "" : "s") left as a placeholder line", .secondaryLabelColor)], spacing: 8))
                }
            }
            let opts = link("Options\u{2026}", #selector(optionsPressed(_:)), tag: 0)
            let finder = button("Show in Finder", #selector(showInFinderPressed(_:)), tag: 0)
            let open = button("Open in Word", #selector(openWordPressed(_:)), tag: 0, primary: true)
            rows.append(hstack([opts, NSView(), finder, open], spacing: 8))
        case .refused:
            rows.append(header(.table, "Not converted", j.message, inner))
            rows.append(hstack([NSView(), button("Open in Jack", #selector(openInJackPressed(_:)), tag: 0),
                                button("Copy Text", #selector(copyTextPressed(_:)), tag: 0, primary: true)], spacing: 8))
        case .failed:
            rows.append(header(.stop, "Couldn\u{2019}t convert", j.message, inner))
            rows.append(hstack([NSView(), button("Open in Jack", #selector(openInJackPressed(_:)), tag: 0),
                                button("Close", #selector(closePressed(_:)), tag: 0, primary: true)], spacing: 8))
        case .stopped:
            rows.append(header(.stop, "Stopped", "Nothing was saved.", inner))
        }
        return vstack(rows)
    }

    // Several PDFs: the mock's board 6.
    private func listView(width: CGFloat) -> NSView {
        let inner = width - 32
        let done = jobs.filter { $0.state == .done }.count
        let working = jobs.filter { $0.state == .working }.count
        let waiting = jobs.filter { $0.state == .waiting }.count
        let refused = jobs.filter { $0.state == .refused || $0.state == .failed }.count
        let stopped = jobs.filter { $0.state == .stopped }.count
        var counts: [String] = []
        if done > 0 { counts.append("\(done) done") }
        if working > 0 { counts.append("\(working) working") }
        if waiting > 0 { counts.append("\(waiting) waiting") }
        if refused > 0 { counts.append("\(refused) not converted") }
        if stopped > 0 { counts.append("\(stopped) stopped") }
        let finished = jobs.allSatisfy { $0.finished }
        let title = finished ? "\(done) of \(jobs.count) PDFs saved as Word" : "Converting \(jobs.count) PDFs to Word"
        var rows: [NSView] = [header(finished ? (done > 0 ? .check : .stop) : .word, title, counts.joined(separator: " \u{00B7} "), inner)]

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 9
        for (i, j) in jobs.enumerated() {
            let name = small(j.output?.lastPathComponent ?? j.name, j.state == .waiting || j.state == .stopped ? .secondaryLabelColor : .labelColor)
            name.lineBreakMode = .byTruncatingMiddle
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            var right: NSView
            switch j.state {
            case .done: right = link("Open", #selector(openWordPressed(_:)), tag: i)
            case .working: right = small(j.pages > 0 ? "page \(min(j.page + 1, j.pages)) of \(j.pages)" : "starting", .secondaryLabelColor)
            case .waiting: right = small("waiting", .secondaryLabelColor)
            case .refused, .failed: right = small("not converted", .systemOrange)
            case .stopped: right = small("stopped", .secondaryLabelColor)
            }
            if j.state == .working { name.font = .systemFont(ofSize: 12, weight: .semibold) }
            let row = hstack([rowIcon(j.state), name, NSView(), right], spacing: 9)
            row.widthAnchor.constraint(equalToConstant: inner).isActive = true
            list.addArrangedSubview(row)
            if j.state == .working {
                let bar = progressBar(j)
                let wrapBar = hstack([bar], spacing: 0)
                wrapBar.edgeInsets = NSEdgeInsets(top: 0, left: 25, bottom: 0, right: 0)
                wrapBar.widthAnchor.constraint(equalToConstant: inner).isActive = true
                list.addArrangedSubview(wrapBar)
            }
            if j.state == .refused || j.state == .failed {
                let why = wrap(j.message, .secondaryLabelColor, inner - 25)
                let w = hstack([why], spacing: 0)
                w.edgeInsets = NSEdgeInsets(top: 0, left: 25, bottom: 0, right: 0)
                list.addArrangedSubview(w)
            }
        }
        rows.append(list)
        if finished {
            var buttons: [NSView] = [NSView()]
            if done > 0 { buttons.append(button("Show in Finder", #selector(showInFinderPressed(_:)), tag: 0, primary: true)) }
            else { buttons.append(button("Close", #selector(closePressed(_:)), tag: 0, primary: true)) }
            rows.append(hstack(buttons, spacing: 8))
        } else {
            rows.append(hstack([NSView(), button("Stop all", #selector(stopPressed(_:)), tag: 0)], spacing: 8))
        }
        return vstack(rows)
    }

    private func statusText(_ j: Job) -> String {
        guard j.pages > 0 else { return "Getting ready\u{2026}" }
        return j.page < j.pages ? "Reading page \(j.page + 1) of \(j.pages)" : "Checking every word against the PDF\u{2026}"
    }

    private func etaText(_ j: Job) -> String {
        guard let t0 = j.started, j.page >= 1, j.page < j.pages else { return "" }
        let per = Date().timeIntervalSince(t0) / Double(j.page)
        let left = per * Double(j.pages - j.page) + 2
        return left < 10 ? "a few seconds left" : left < 90 ? "about \(Int((left / 5).rounded()) * 5) s left" : "about \(Int((left / 60).rounded())) min left"
    }

    // MARK: Small builders

    private func vstack(_ rows: [NSView]) -> NSStackView {
        let s = NSStackView(views: rows)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 12
        s.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        for r in rows { r.trailingAnchor.constraint(equalTo: s.trailingAnchor, constant: -16).isActive = true }
        return s
    }

    private func hstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        for v in views where type(of: v) == NSView.self {   // spacers
            v.setContentHuggingPriority(.init(1), for: .horizontal)
        }
        return s
    }

    private func header(_ kind: CardGlyph.Kind, _ title: String, _ subtitle: String, _ inner: CGFloat) -> NSView {
        let g = CardGlyph(kind: kind)
        g.translatesAutoresizingMaskIntoConstraints = false
        g.widthAnchor.constraint(equalToConstant: 34).isActive = true
        g.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13.5, weight: .semibold)
        t.textColor = .labelColor
        let sub = wrap(subtitle, .secondaryLabelColor, inner - 45)
        sub.font = .systemFont(ofSize: 11.5)
        let text = NSStackView(views: [t, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let h = NSStackView(views: [g, text])
        h.orientation = .horizontal
        h.alignment = subtitle.count > 60 ? .top : .centerY
        h.spacing = 11
        return h
    }

    private func small(_ s: String, _ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11.5)
        l.textColor = color
        return l
    }

    private func wrap(_ s: String, _ color: NSColor, _ width: CGFloat) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 12)
        l.textColor = color
        l.preferredMaxLayoutWidth = width
        l.isSelectable = false
        return l
    }

    private func icon(_ symbol: String, _ color: NSColor) -> NSImageView {
        let v = NSImageView(image: Chrome.symbol([symbol], "", NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)) ?? NSImage())
        v.contentTintColor = color
        return v
    }

    private func rowIcon(_ state: Job.State) -> NSView {
        let name: String
        let color: NSColor
        switch state {
        case .done: name = "checkmark.circle"; color = accent
        case .working: name = "circle.dotted"; color = accent
        case .waiting, .stopped: name = "circle"; color = .tertiaryLabelColor
        case .refused, .failed: name = "exclamationmark.circle"; color = .systemOrange
        }
        let v = NSImageView(image: Chrome.symbol([name], "", NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) ?? NSImage())
        v.contentTintColor = color
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return v
    }

    private func swatch() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedRed: 0.992, green: 0.902, blue: 0.541, alpha: 1).cgColor
        v.layer?.cornerRadius = 2
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 14).isActive = true
        v.heightAnchor.constraint(equalToConstant: 10).isActive = true
        return v
    }

    private func progressBar(_ j: Job) -> NSProgressIndicator {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        if j.pages > 0 {
            bar.isIndeterminate = false
            bar.maxValue = Double(j.pages)
            bar.doubleValue = Double(min(j.page + 1, j.pages))
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        return bar
    }

    private func button(_ title: String, _ action: Selector, tag: Int, primary: Bool = false) -> NSButton {
        let b = FirstMouseButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.tag = tag
        if primary { b.keyEquivalent = "\r" }
        return b
    }

    private func link(_ title: String, _ action: Selector, tag: Int) -> NSButton {
        let b = FirstMouseButton(title: title, target: self, action: action)
        b.isBordered = false
        b.tag = tag
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: accent, .font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        return b
    }

    // MARK: Self-test (JACK_CONVERT_SELFTEST=<dir> Jack a.pdf b.pdf …)

    /// Drives the real card on the PDFs given as arguments, captures it, logs every state, exits.
    /// JACK_CONVERT_SELFTEST_STOP=1 presses Stop on the first progress tick instead.
    static func runSelfTestIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["JACK_CONVERT_SELFTEST"] else { return false }
        let pdfs = CommandLine.arguments.dropFirst().filter { $0.lowercased().hasSuffix(".pdf") }.map { URL(fileURLWithPath: $0) }
        let wantStop = ProcessInfo.processInfo.environment["JACK_CONVERT_SELFTEST_STOP"] != nil
        var log = "Convert card self-test \(Date())\n"
        // C1: what the Drop Shelf offers for these files.
        if let c = DropShelf.classify(pdfs) {
            log += "shelf: \(c.action) | split: \(c.split.map { "\($0.left.action) / \($0.right.action)" } ?? "none")\n"
        }
        // C1: capture the shelf itself (no drag needed).
        let shelf = DropShelf(onDrop: { _ in }, onConvert: { _ in })
        if let v = shelf.showcase(pdfs), let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/0-shelf.png"))
            log += "captured 0-shelf \(Int(v.bounds.width))x\(Int(v.bounds.height))\n"
        }
        shelf.hide()
        let card = WordConvertCard.shared
        var last = ""
        var pressedStop = false
        var shots = 0
        func capture(_ name: String) {
            guard let v = card.panel?.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            log += "captured \(name) \(Int(v.bounds.width))x\(Int(v.bounds.height))\n"
        }
        card.onRender = { line in
            guard line != last else { return }
            last = line
            log += "render: \(line)\n"
            if wantStop, !pressedStop, card.jobs.contains(where: { $0.state == .working && $0.page >= 1 }) {
                pressedStop = true
                DispatchQueue.main.async { card.stopAll() }
            }
            if shots == 0, card.jobs.contains(where: { $0.state == .working && $0.pages > 0 }) {
                shots = 1
                DispatchQueue.main.async { capture("1-working") }
            }
        }
        card.convert(pdfs)
        var waited = 0.0
        func poll() {
            if !card.running && card.jobs.allSatisfy({ $0.finished }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    capture("2-finished")
                    let ok = !card.jobs.isEmpty && card.jobs.allSatisfy { $0.finished && $0.state != .failed }
                        && (!wantStop || card.jobs.allSatisfy { $0.state == .stopped && $0.output == nil })
                        && card.jobs.allSatisfy { $0.output.map { FileManager.default.fileExists(atPath: $0.path) } ?? true }
                    for j in card.jobs { if let o = j.output { log += "output \(o.path)\n" } }
                    log += ok ? "PASS\n" : "FAIL\n"
                    print(log)
                    try? log.write(toFile: "\(dir)/convert-selftest.log", atomically: true, encoding: .utf8)
                    exit(ok ? 0 : 1)
                }
                return
            }
            waited += 0.5
            if waited > 300 { log += "timed out\nFAIL\n"; try? log.write(toFile: "\(dir)/convert-selftest.log", atomically: true, encoding: .utf8); exit(1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
        return true
    }
}

/// Non-activating, but able to take Esc once the user clicks it.
final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class CardView: NSVisualEffectView {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// Buttons in a panel that never activates Jack must answer the very first click.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The card's 34 pt glyph: teal gradient with a white mark (Word / done), amber table (refused),
/// grey stop (stopped or failed). Drawn, never an emoji.
final class CardGlyph: NSView {
    enum Kind { case word, check, table, stop, open, organize }
    var kind: Kind
    init(kind: Kind) { self.kind = kind; super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        CardGlyph.draw(kind, in: bounds, ctx: ctx)
    }

    static func draw(_ kind: Kind, in r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 9 * r.width / 34, cornerHeight: 9 * r.width / 34, transform: nil))
        ctx.clip()
        var stroke = NSColor.white.cgColor
        switch kind {
        case .table:
            ctx.setFillColor(NSColor(calibratedRed: 0.953, green: 0.890, blue: 0.780, alpha: 1).cgColor)
            ctx.fill(r)
            stroke = NSColor(calibratedRed: 0.541, green: 0.353, blue: 0.043, alpha: 1).cgColor
        case .stop:
            ctx.setFillColor(NSColor(calibratedWhite: 0.88, alpha: 1).cgColor)
            ctx.fill(r)
            stroke = NSColor(calibratedWhite: 0.36, alpha: 1).cgColor
        default:
            let colors = [NSColor(calibratedRed: 0.055, green: 0.431, blue: 0.431, alpha: 1).cgColor,
                          NSColor(calibratedRed: 0.078, green: 0.722, blue: 0.651, alpha: 1).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
            }
        }
        // Marks drawn on a 24-unit grid (SVG-style, y down), centred at 20/34 of the tile.
        let s = r.width * (20.0 / 34.0) / 24
        let ox = r.minX + (r.width - 24 * s) / 2, oy = r.minY + (r.height - 24 * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + (24 - y) * s) }
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(1.8 * s)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch kind {
        case .word:
            ctx.move(to: p(14, 3.5)); ctx.addLine(to: p(7, 3.5)); ctx.addLine(to: p(5, 5.5)); ctx.addLine(to: p(5, 18.5))
            ctx.addLine(to: p(7, 20.5)); ctx.addLine(to: p(17, 20.5)); ctx.addLine(to: p(19, 18.5)); ctx.addLine(to: p(19, 8.5))
            ctx.closePath()
            ctx.move(to: p(14, 3.5)); ctx.addLine(to: p(14, 8.5)); ctx.addLine(to: p(19, 8.5))
            ctx.move(to: p(8.5, 12.5)); ctx.addLine(to: p(9.8, 17.5)); ctx.addLine(to: p(11.5, 13.9))
            ctx.addLine(to: p(13.2, 17.5)); ctx.addLine(to: p(14.5, 12.5))
        case .check:
            ctx.setLineWidth(2.2 * s)
            ctx.move(to: p(6, 12.5)); ctx.addLine(to: p(10, 16.5)); ctx.addLine(to: p(18, 8))
        case .table:
            ctx.addPath(CGPath(roundedRect: CGRect(x: p(4, 19).x, y: p(4, 19).y, width: 16 * s, height: 14 * s),
                               cornerWidth: 2 * s, cornerHeight: 2 * s, transform: nil))
            ctx.move(to: p(4, 10)); ctx.addLine(to: p(20, 10))
            ctx.move(to: p(10, 10)); ctx.addLine(to: p(10, 19))
        case .stop:
            ctx.move(to: p(8, 8)); ctx.addLine(to: p(16, 16))
            ctx.move(to: p(16, 8)); ctx.addLine(to: p(8, 16))
        case .open:   // up-arrow into a tray (the Drop Shelf's original mark)
            ctx.setLineWidth(1.9 * s)
            ctx.move(to: p(12, 4)); ctx.addLine(to: p(12, 14))
            ctx.move(to: p(8, 8)); ctx.addLine(to: p(12, 4)); ctx.addLine(to: p(16, 8))
            ctx.move(to: p(4, 14)); ctx.addLine(to: p(4, 18)); ctx.addLine(to: p(6, 20)); ctx.addLine(to: p(18, 20))
            ctx.addLine(to: p(20, 18)); ctx.addLine(to: p(20, 14))
        case .organize:   // stacked pages
            ctx.addPath(CGPath(roundedRect: CGRect(x: p(6, 18.5).x, y: p(6, 18.5).y, width: 12 * s, height: 15 * s),
                               cornerWidth: 1.5 * s, cornerHeight: 1.5 * s, transform: nil))
            ctx.move(to: p(9, 21)); ctx.addLine(to: p(18, 21)); ctx.addLine(to: p(20, 19)); ctx.addLine(to: p(20, 8))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
