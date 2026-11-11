// Save as Word — the sheet (ratified mock, Luis 2026-11-11:
// https://claude.ai/artifact/1hBR6cXR2rA3oQ33QnLgSK, decisions W1–W6).
//
// One ToolSheet, four states: options → working (Stop) → result → or an honest refusal.
//   W1 doors: Share ▸ Save as Word…, File ▸ Export as Word… (⇧⌘W), Finder right-click on a PDF.
//   W2 Match pages is the default; Flowing text is the option.
//   W3 words to double-check are highlighted yellow (on by default; the sheet warns when off).
//   W4 signatures are never copied (the engine writes a placeholder line).
//   W5 tables / columns are refused with a reason; Copy Text is offered instead.
// The .docx lands beside the PDF (never clobbering); an untitled PDF asks where.
import AppKit
import PDFKit

extension DocumentWindowController {

    @objc func saveAsWord(_ sender: Any?) {
        guard let doc = pdfView.document, let data = doc.dataRepresentation(), doc.pageCount > 0 else { return }
        let total = doc.pageCount
        let source = (document as? NSDocument)?.fileURL
        let title = source?.deletingPathExtension().lastPathComponent ?? "Untitled"

        let sheet = ToolSheet(symbol: "doc.richtext", title: "Save as Word",
                              purpose: "Make an editable Word document from this PDF. Read and rebuilt on this Mac; nothing is uploaded.",
                              note: ("doc.on.doc", "Saves a new .docx \u{00B7} this PDF stays as it is"),
                              primary: "Save as Word", preview: true)
        if let first = doc.page(at: 0) { sheet.setPreview(toolPreview(first)) }

        let found = ToolSheet.note("\(total) page\(total == 1 ? "" : "s")")
        let layout = ToolSheet.segmented(["Match pages", "Flowing text"], selected: 0)
        let layoutHint = ToolSheet.note("New pages start where the PDF\u{2019}s pages start. Best for contracts and forms you will print or sign.")
        let letterhead = NSButton(checkboxWithTitle: "Letterhead logo on every page", target: nil, action: nil)
        letterhead.state = .on
        let mark = NSButton(checkboxWithTitle: "Highlight words to double-check", target: nil, action: nil)
        mark.state = .on
        let markHint = ToolSheet.note("Words the scan made hard to read are marked yellow in Word. Remove the highlight once checked.")
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.isHidden = true
        let big = ToolSheet.bigValue("")
        big.isHidden = true

        sheet.addRow("Found", found)
        sheet.addRow("Layout", layout)
        sheet.addRow(nil, layoutHint)
        sheet.addRow("Keep", letterhead)
        sheet.addRow(nil, mark)
        sheet.addRow(nil, markHint)
        sheet.addRow("Result", big)
        let optionViews: [NSView] = [layout, layoutHint, letterhead, mark, markHint]
        sheet.addRow("Working", bar)

        // How many pages are scans (cheap: text layer + page-sized image), off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let copy = PDFDocument(data: data)
            var scans = 0
            for i in 0..<(copy?.pageCount ?? 0) {
                guard let p = copy?.page(at: i) else { continue }
                let text = (p.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count <= 20 || WordExportEngine.isScanPage(p) { scans += 1 }
            }
            DispatchQueue.main.async { [weak sheet] in
                guard let sheet else { return }
                found.stringValue = scans == 0 ? "\(total) page\(total == 1 ? "" : "s") with text"
                    : scans == total ? "\(total) scanned page\(total == 1 ? "" : "s")"
                    : "\(total) pages \u{00B7} \(scans) scanned"
                sheet.layout()
            }
        }

        ControlAction.bind(layout) { [weak sheet] _ in
            layoutHint.stringValue = layout.selectedSegment == 0
                ? "New pages start where the PDF\u{2019}s pages start. Best for contracts and forms you will print or sign."
                : "One continuous document. Best when you will rewrite or reuse the text."
            sheet?.layout()
        }
        ControlAction.bind(mark) { [weak sheet] _ in
            if mark.state == .on {
                markHint.stringValue = "Words the scan made hard to read are marked yellow in Word. Remove the highlight once checked."
                markHint.textColor = .secondaryLabelColor
            } else {
                markHint.stringValue = "Uncertain words will look exactly like the rest. Proofread the whole document before you send it."
                markHint.textColor = .systemOrange
            }
            sheet?.layout()
        }

        enum Phase { case options, working, done(URL), refused(String), failed }
        var phase = Phase.options
        var stop = false
        let stopLock = NSLock()

        func showResult(_ url: URL, _ r: WordExportEngine.Report) {
            phase = .done(url)
            bar.isHidden = true
            big.isHidden = false
            big.stringValue = String(format: "%.1f%% match", r.agreement * 100)
            // The result replaces the options, so the sheet stays short enough for any window.
            for v in optionViews { v.isHidden = true }
            var lines: [String] = []
            var tone: ToolSheet.Tone = .ok
            if let m = r.missingPages {
                lines.append("Pages \(m.lowerBound)\u{2013}\(m.upperBound) aren\u{2019}t in this PDF (the footers say \(m.upperBound)). Get them before relying on it.")
                tone = .warn
            }
            lines.append("\(url.lastPathComponent) is ready next to the PDF \u{00B7} \(r.pages) page\(r.pages == 1 ? "" : "s"). "
                + (r.scannedPages > 0 ? "Each word was read twice to check it." : "Each word was checked against the PDF\u{2019}s text."))
            if r.uncertainWords > 0 {
                lines.append(mark.state == .on
                    ? "\(r.uncertainWords) word\(r.uncertainWords == 1 ? "" : "s") highlighted yellow to check."
                    : "\(r.uncertainWords) uncertain word\(r.uncertainWords == 1 ? "" : "s"), not highlighted.")
            }
            if r.signaturePlaceholders > 0 {
                lines.append("\(r.signaturePlaceholders) signature\(r.signaturePlaceholders == 1 ? "" : "s") left out, with a placeholder line.")
            }
            if r.checkboxes > 0 { lines.append("\(r.checkboxes) checkbox\(r.checkboxes == 1 ? "" : "es") you can tick, \(r.checkedBoxes) ticked as in the PDF.") }
            sheet.setMessage(lines.joined(separator: "\n"), tone)
            sheet.cancelButton.title = "Show in Finder"
            sheet.cancelButton.keyEquivalent = ""
            sheet.setCancelVisible(true)
            sheet.setNote(symbol: "doc.on.doc", "This PDF stays as it is")
            sheet.setPrimary("Open in Word")
            NSSound(named: "Glass")?.play()
        }

        func run(to out: URL) {
            phase = .working
            stopLock.lock(); stop = false; stopLock.unlock()
            for v in [layout, letterhead, mark] { v.isEnabled = false }
            bar.isHidden = false
            bar.maxValue = Double(total)
            bar.doubleValue = 0
            sheet.setPrimary("Saving\u{2026}", enabled: false)
            sheet.cancelButton.title = "Stop"
            sheet.setMessage("Reading page 1 of \(total)", .hint)
            var opts = WordExportEngine.Options()
            opts.matchPages = layout.selectedSegment == 0
            opts.keepLetterhead = letterhead.state == .on
            opts.markUncertain = mark.state == .on
            DispatchQueue.global(qos: .userInitiated).async {
                // PDFKit isn't thread-safe: the engine works on its own copy of what's on screen.
                guard let work = PDFDocument(data: data) else {
                    DispatchQueue.main.async {
                        phase = .failed
                        sheet.setMessage("The document couldn\u{2019}t be copied for conversion. Nothing was saved.", .error)
                        sheet.setPrimary("Done"); sheet.setCancelVisible(false)
                    }
                    return
                }
                let result: Result<WordExportEngine.Report, Error> = Result {
                    try WordExportEngine.export(work, to: out, title: title, options: opts, progress: { i, n in
                        DispatchQueue.main.async {
                            bar.doubleValue = Double(min(i + 1, n))
                            sheet.setMessage(i < n ? "Reading page \(i + 1) of \(n)"
                                                   : "Rebuilding the layout and checking every word against the PDF\u{2026}", .hint)
                        }
                    }, cancelled: { stopLock.lock(); defer { stopLock.unlock() }; return stop })
                }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let r):
                        // Stopped after the file was already written: honour the Stop.
                        stopLock.lock(); let wasStopped = stop; stopLock.unlock()
                        if wasStopped { try? FileManager.default.removeItem(at: out); return }
                        showResult(out, r)
                    case .failure(let e):
                        try? FileManager.default.removeItem(at: out)
                        bar.isHidden = true
                        for v in optionViews { v.isHidden = true }
                        if case WordExportEngine.ExportError.refused(let why, let text) = e {
                            phase = .refused(text)
                            sheet.setMessage(why, .warn)
                            sheet.cancelButton.title = "Close"
                            sheet.setCancelVisible(true)
                            sheet.setNote(symbol: "doc.on.doc", "Nothing was saved")
                            sheet.setPrimary("Copy Text")
                        } else {
                            phase = .failed
                            sheet.setMessage(e.localizedDescription, e is WordExportEngine.ExportError ? .warn : .error)
                            sheet.setCancelVisible(false)
                            sheet.setNote(symbol: "doc.on.doc", "Nothing was saved")
                            sheet.setPrimary("Done")
                        }
                    }
                    sheet.layout()
                }
            }
        }

        // Stop while working; Show in Finder on the result; Close on a refusal.
        sheet.onCancel = { [weak self] in
            switch phase {
            case .working:
                stopLock.lock(); stop = true; stopLock.unlock()
            case .done(let url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
            default:
                break
            }
            _ = self
        }
        sheet.onPrimary = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            switch phase {
            case .options:
                if let src = source, FileManager.default.isWritableFile(atPath: src.deletingLastPathComponent().path) {
                    run(to: WordExportEngine.outputURL(for: src))
                } else {
                    // Untitled, or a folder Jack can't write to: ask where.
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = title + ".docx"
                    panel.allowedFileTypes = ["docx"]
                    panel.beginSheetModal(for: sheet.window) { resp in
                        if resp == .OK, let url = panel.url { run(to: url) }
                    }
                }
            case .working:
                break
            case .done(let url):
                NSWorkspace.shared.open(url)
                self.finishSheet(sheet)
            case .refused(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.finishSheet(sheet)
            case .failed:
                self.finishSheet(sheet)
            }
        }
        showSheet(sheet)
    }
}
