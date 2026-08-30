// v2.0: Jack adopts the native document architecture — Duplicate, Rename/Move, and the
// document undo stack come from NSDocument.
//
// v2.5 LAW CHANGE: autosave-in-place is OFF. Edits accumulate on the open document and are
// written to disk ONLY when the user saves. The first save of a PDF Jack did not produce
// defaults to a NEW COPY ("<name>-edited.pdf") so someone else's original is never silently
// rewritten; once the document IS Jack's own file, ⌘S writes straight into it. Crash safety
// comes from autosave-elsewhere (a scratch file under ~/Library/Autosave Information), which
// never touches the user's original. Versions is gone with autosave-in-place — Revert to Saved
// replaces it.
//
// What gets written into the file (buildPersistedDocument):
// - Pages WITHOUT signature stamps: copied verbatim — form fields, text layer, and native
//   annotations (highlights, underlines, notes) all survive untouched.
// - Pages WITH signature stamps: flattened (stamps + field values burned) — our stamp
//   annotations can't serialize an appearance, and signing finalizes a page anyway.
// - Comment badges become standard .text notes (readable in any PDF app; Jack reopens
//   them as clickable pins). Pending redaction marks are session-only UI and are dropped.
import AppKit
import PDFKit

extension Notification.Name {
    /// Posted whenever a document's edited state changes, so window chrome (Save button,
    /// subtitle) can follow. NSDocument has no such notification of its own.
    static let jackDocumentDirtyChanged = Notification.Name("jack.documentDirtyChanged")
}

@objc(JackDocument)
final class JackDocument: NSDocument, PDFDocumentDelegate {
    // Every page renders through JackPage so Jack's field chrome (the approved Form Kit)
    // draws in the view, thumbnails, and flattens. Set as the PDFDocument's delegate
    // BEFORE any page is touched — PDFKit creates page objects lazily.
    func classForPage() -> AnyClass { JackPage.self }

    var pdf: PDFDocument?

    /// Written into /Creator on every save so a reopened file is recognizable as Jack's own —
    /// that is what lets ⌘S write in place instead of offering a copy again.
    static let creatorMarker = "Jack (ThinkOpen)"

    /// This file was produced by Jack (marker found on read), so it IS the working copy.
    private(set) var isJackProduced = false
    /// The user has saved during this session, so `fileURL` now points at their own copy.
    private(set) var hasSavedCopy = false
    /// Set only while routing a first save through the save panel, to seed the "-edited" name.
    private var pendingCopyName: String?

    /// Set by the last build when the written document lost its searchable text.
    /// 🧨 PDFKit's writer converts text to vector OUTLINES for fonts it cannot re-embed — the
    /// page looks pixel-identical while becoming unsearchable and several times larger. It is
    /// invisible unless we measure it, so we measure it and say so.
    private var droppedTextLayer = false

    /// True while the file on disk is still the one the user opened, untouched.
    ///
    /// v2.6.1: this deliberately no longer exempts Jack's OWN files. Keno's rule is simply
    /// "keep the original" — so the FIRST save of any existing document in a session goes to a
    /// new file, whoever made it. Later saves in the same session write to that new file rather
    /// than spawning one per ⌘S.
    var protectsOriginal: Bool { fileURL != nil && !hasSavedCopy }

    override class var autosavesInPlace: Bool { false }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    // Keeps Open Recent fresh across first saves, renames, and moves — not just opens.
    override var fileURL: URL? {
        didSet { if let u = fileURL { RecentDocuments.record(u) } }
    }

    // File → New PDF (⌘N): an untitled document is one blank US-Letter page, ready for
    // form fields, markup, and more pages via the sidebar. Saves through the normal flow.
    convenience init(type typeName: String) throws {
        self.init()
        fileType = typeName
        let blank = PDFDocument()
        blank.delegate = self
        blank.insert(JackPage(), at: 0)
        pdf = blank
    }

    override func read(from url: URL, ofType typeName: String) throws {
        guard let doc = PDFDocument(url: url) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                          userInfo: [NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” couldn’t be read as a PDF."])
        }
        doc.delegate = self    // before baseline/page access — lazy pages become JackPage
        // Jack renders supported widgets itself (JackPage chrome); PDFView's own widget
        // painting sits ON TOP of the page render and would cover it. Runtime-only —
        // buildPersistedDocument restores visibility on everything it writes.
        for i in 0..<doc.pageCount {
            guard let pg = doc.page(at: i) else { continue }
            for a in pg.annotations where JackFormUI.isSupported(a) { a.shouldDisplay = false }
        }
        pdf = doc
        originalURLForReveal = url
        if let raw = try? Data(contentsOf: url) {
            incrementalBaseline = IncrementalSave.baseline(for: doc, data: raw)
        }
        isJackProduced = (doc.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String)
            == JackDocument.creatorMarker
        hasSavedCopy = false
        RecentDocuments.record(url)
        // Restoration can build window controllers before this read lands — attach late.
        DispatchQueue.main.async { [weak self] in
            self?.windowControllers.compactMap { $0 as? DocumentWindowController }
                .forEach { $0.attachDocumentIfNeeded() }
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        // FIRST CHOICE: the incremental save. PDFKit's writer outlines text for fonts it
        // cannot re-embed, so untouched pages must keep their ORIGINAL bytes. Only pages Jack
        // itself rasterized are appended; the result must self-verify (untouched-page text
        // identical, swapped pages render) or we fall back to the full rewrite below —
        // worst case is exactly yesterday's behavior. Widget-bearing docs always fall back:
        // typed form values change annotation STATE without changing the annotation set,
        // and the incremental path would silently drop them.
        func diag(_ msg: String) {
            let line = "[\(Date())] \(msg)\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/jack-save-diag.log") {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
            } else {
                try? line.write(toFile: "/tmp/jack-save-diag.log", atomically: true, encoding: .utf8)
            }
        }
        if let live = pdf {
            if incrementalBaseline == nil {
                diag("gate: NO BASELINE (doc not opened via read(from:)?)")
            } else if FormFieldEngine.hasWidgets(live) {
                diag("gate: widgets present → fallback by design")
            } else if let baseline = incrementalBaseline {
                IncrementalSave.lastBailReason = ""
                if let candidate = IncrementalSave.build(current: live, baseline: baseline) {
                    let issues = IncrementalSave.verify(candidate: candidate, current: live, baseline: baseline)
                    if issues.isEmpty {
                        diag("gate: INCREMENTAL OK (\(candidate.count) bytes)")
                        droppedTextLayer = false
                        incrementalBaseline = IncrementalSave.baseline(for: live, data: candidate)
                        return candidate
                    } else {
                        diag("gate: verify FAILED — \(issues.joined(separator: " | "))")
                    }
                } else {
                    diag("gate: build nil — \(IncrementalSave.lastBailReason)")
                }
            }
            diag("gate: FALLBACK path runs")
        }

        guard let live = pdf,
              let out = JackDocument.buildPersistedDocument(from: live),
              let data = out.dataRepresentation() else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn’t serialize the PDF."])
        }
        droppedTextLayer = JackDocument.textLength(of: live) > 200
            && JackDocument.textLength(of: out) < JackDocument.textLength(of: live) / 4

        // The fresh-document rebuild drops /AcroForm (fields go dead in Acrobat/Chrome)
        // and loses radio /V + /AS. Repair both at the byte level; no-op for widget-free docs.
        let final = FormFieldEngine.hasWidgets(live)
            ? AcroFormFixup.fix(data: data, radioAsserts: FormFieldEngine.radioAsserts(from: live))
            : data
        // Disk is now PDFKit-normalized (classic xref) — future saves can increment on top,
        // and the live pages ARE the file's pages again.
        incrementalBaseline = IncrementalSave.baseline(for: live, data: final)
        return final
    }

    override func makeWindowControllers() {
        let wc = DocumentWindowController(document: self)
        addWindowController(wc)
    }

    // MARK: - Save routing (v2.5)

    // ⌘S on a PDF Jack did not produce saves a COPY the first time, with the panel pre-filled
    // "<name>-edited.pdf" beside the original — one Return and the original stays untouched.
    // Afterwards `fileURL` is the user's own copy and this falls through to a plain save.
    // NOTE: Swift renames the ObjC `saveDocument:`/`saveDocumentAs:` actions to
    // `save(_:)`/`saveAs(_:)`. Overriding `save(_:)` DOES replace the ObjC implementation, so
    // ⌘S from the menu (Selector("saveDocument:")) lands here.
    override func save(_ sender: Any?) {
        guard prepareCopyIfProtecting() else {
            super.save(sender)
            return
        }
        saveAs(sender)
    }

    // 🧨 The close-with-unsaved-changes sheet does NOT go through save(_:). Its Save button
    // calls this, which without an override writes straight to the user's original file — no
    // panel, no copy. That is how an original got overwritten in v2.5/2.6 even though ⌘S was
    // handled correctly. Any future save entry point must be routed through here too.
    override func save(withDelegate delegate: Any?, didSave didSaveSelector: Selector?,
                       contextInfo: UnsafeMutableRawPointer?) {
        guard prepareCopyIfProtecting() else {
            super.save(withDelegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
            return
        }
        // Run the panel but keep the caller's completion, so the close flow still finishes.
        runModalSavePanel(for: .saveAsOperation, delegate: delegate,
                          didSave: didSaveSelector, contextInfo: contextInfo)
    }

    /// Returns true when this save must become a copy, seeding the suggested name.
    private func prepareCopyIfProtecting() -> Bool {
        guard protectsOriginal, let current = fileURL else { return false }
        // Don't stack suffixes: "Report-edited.pdf" edited again is still "Report-edited.pdf".
        let base = current.deletingPathExtension().lastPathComponent
        pendingCopyName = (base.hasSuffix("-edited") ? base : base + "-edited") + ".pdf"
        return true
    }

    override func prepareSavePanel(_ panel: NSSavePanel) -> Bool {
        if let name = pendingCopyName {
            panel.nameFieldStringValue = name
            panel.directoryURL = fileURL?.deletingLastPathComponent()
            panel.message = "Your changes will be saved as a new PDF. The original stays as it is."
        }
        return super.prepareSavePanel(panel)
    }

    // Every save funnels through here. A real (non-autosave) write means the document now has
    // its own file on disk — later ⌘S goes straight to it.
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            let isAutosave = saveOperation == .autosaveElsewhereOperation
                || saveOperation == .autosaveInPlaceOperation
                || saveOperation == .autosaveAsOperation
            if error == nil, !isAutosave {
                self?.hasSavedCopy = true
                self?.pendingCopyName = nil
                self?.postDirtyChanged()
                self?.emitRedactionCertificateIfNeeded(savedTo: url)
                self?.warnIfTextLayerDropped(savedTo: url)
            }
            completionHandler(error)
        }
    }

    // NSDocument posts nothing when the edited flag flips; the window chrome needs to know.
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        postDirtyChanged()
    }

    /// Tell the user plainly when a save produced a file that is no longer searchable. The
    /// original they opened is untouched by then — the copy rule guarantees that — so this is
    /// information, not an emergency.
    private func warnIfTextLayerDropped(savedTo url: URL) {
        guard droppedTextLayer else { return }
        droppedTextLayer = false
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Saved, but the text is no longer selectable"
        a.informativeText = "“\(url.lastPathComponent)” looks identical, but this document uses embedded "
            + "fonts macOS cannot rewrite, so its text became outlines — search and text selection will not "
            + "work in it, and the file is larger.\n\nThe original you opened is unchanged. Use it whenever "
            + "you need the searchable version."
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Show the Original")
        if a.runModal() == .alertSecondButtonReturn, let original = originalURLForReveal {
            NSWorkspace.shared.activateFileViewerSelecting([original])
        }
    }

    /// The file this document was opened from, remembered before the first save moved us.
    private var originalURLForReveal: URL?

    /// Snapshot for the incremental save: the file's original bytes plus what each page looked
    /// like at load. Refreshed after every successful save so ⌘S chains further increments.
    private var incrementalBaseline: IncrementalSave.Baseline?

    private func postDirtyChanged() {
        NotificationCenter.default.post(name: .jackDocumentDirtyChanged, object: self)
    }

    // v2.5: redaction applies in place, so the certificate is issued here — against the file
    // the user actually wrote, not an intermediate. The primary guarantee is already met by
    // then: every redacted page was verified to carry zero extractable text BEFORE it entered
    // the document, so unverifiable content never reaches disk in the first place.
    //
    // NOTE — this deliberately narrows the v1.5 "unverified output is DELETED" rule. That rule
    // protected a deliverable Jack authored on its own. Here the file is one the user asked to
    // save, and silently deleting their document would be the worse failure. The gate moved
    // EARLIER (pre-swap) instead; this pass is a second net that reports rather than destroys.
    private func emitRedactionCertificateIfNeeded(savedTo url: URL) {
        guard let wc = windowControllers.compactMap({ $0 as? DocumentWindowController }).first,
              let info = wc.pendingCertificateInfo else { return }

        let issues = RedactionEngine.verify(outputURL: url, redactedPages: info.pages,
                                            forbiddenTerms: info.terms, checkMetadata: false)
        guard issues.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Saved, but the redaction did NOT verify"
            alert.informativeText = "“\(url.lastPathComponent)” was written as you asked, but it failed "
                + "verification and may still contain recoverable content. Do not distribute it.\n\n• "
                + issues.joined(separator: "\n• ")
            alert.runModal()
            return
        }

        let certURL = url.deletingPathExtension().appendingPathExtension("certificate.pdf")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let ok = CertificateEngine.generate(forRedacted: url, redactedPages: info.pages,
                                            regionCount: info.regions, terms: info.terms,
                                            appVersion: version, metadataStripped: false, to: certURL)
        wc.noteCertificate(ok ? "Redaction verified — certificate saved as \(certURL.lastPathComponent)"
                              : "Redaction verified — the certificate could not be written")
    }

    // MARK: - Persistence builder

    static func textLength(of doc: PDFDocument) -> Int {
        var n = 0
        for i in 0..<doc.pageCount {
            n += (doc.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        return n
    }

    static func buildPersistedDocument(from live: PDFDocument) -> PDFDocument? {
        let out = PDFDocument()
        var outIndex = 0
        for i in 0..<live.pageCount {
            guard let page = live.page(at: i) else { continue }
            // Watermark/Bates burn into the page as real vector content, so a page carrying
            // one is flattened exactly like a signed page.
            let hasStamps = page.annotations.contains { $0 is ImageStampAnnotation || $0 is OverlayAnnotation }
            var persisted: PDFPage?
            if hasStamps {
                persisted = flattenedCopy(of: page, pageIndex: i)
                // Backstop: if a flatten ever comes back without the page's content, write the
                // page VERBATIM instead. Losing a burned-in watermark is recoverable; writing a
                // blank page over the user's content is not.
                if persisted == nil || !RedactionEngine.preservesContent(original: page, replacement: persisted!, regions: []) {
                    persisted = page.copy() as? PDFPage
                }
            } else {
                persisted = page.copy() as? PDFPage
            }
            guard let p = persisted else { continue }

            // Ephemeral overlays never reach disk; badges convert to standard notes.
            // Widgets hidden for Jack's own rendering become visible again — a written
            // file must NEVER carry /F hidden on form fields (Acrobat would blank them).
            for ann in p.annotations {
                if ann is RedactionAnnotation { p.removeAnnotation(ann) }
                if ann.type == "Widget" { ann.shouldDisplay = true }
            }
            for ann in page.annotations.compactMap({ $0 as? CommentBadgeAnnotation }) {
                // Remove any straggler badge on the copy, then add the portable note.
                if let stray = p.annotations.first(where: { $0.bounds == ann.bounds && $0.type == "Stamp" }) {
                    p.removeAnnotation(stray)
                }
                let note = PDFAnnotation(bounds: ann.bounds, forType: .text, withProperties: nil)
                note.contents = ann.contents
                note.color = .systemYellow
                p.addAnnotation(note)
            }
            out.insert(p, at: outIndex)
            outIndex += 1
        }
        guard outIndex > 0 else { return nil }
        // The marker is what tells a later open "this is Jack's own file" — so ⌘S writes
        // straight into it instead of offering a copy a second time.
        var attrs = out.documentAttributes ?? [:]
        attrs[PDFDocumentAttribute.creatorAttribute] = JackDocument.creatorMarker
        out.documentAttributes = attrs
        return out
    }

    // Render one page (with stamps burned, overlays stripped) through a single-page PDF
    // context, so the flattened result can sit beside verbatim vector pages.
    private static func flattenedCopy(of page: PDFPage, pageIndex: Int = 0) -> PDFPage? {
        var box = page.bounds(for: .mediaBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
        ctx.beginPDFPage(info)

        let overlays = page.annotations.filter { $0 is RedactionAnnotation || $0 is CommentBadgeAnnotation }
        overlays.forEach { page.removeAnnotation($0) }
        let stamps = page.annotations.compactMap { $0 as? ImageStampAnnotation }
        stamps.forEach { page.removeAnnotation($0) }
        // Marks that burn as vector content — pulled out so page.draw cannot double-draw them,
        // then drawn into the context by hand (custom annotations never render via page.draw).
        let marks = page.overlayAnnotations
        marks.forEach { page.removeAnnotation($0) }
        ctx.saveGState()
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        for m in marks {
            ctx.saveGState()
            if let b = m as? BatesAnnotation {
                b.drawInto(ctx, pageBox: box, pageIndex: pageIndex)
            } else {
                m.drawInto(ctx, pageBox: box)
            }
            ctx.restoreGState()
        }
        marks.forEach { page.addAnnotation($0) }
        for s in stamps {
            if let cg = s.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.saveGState()
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: s.bounds)
                ctx.restoreGState()
            }
            page.addAnnotation(s)   // keep the live doc intact
        }
        overlays.forEach { page.addAnnotation($0) }

        ctx.endPDFPage()
        ctx.closePDF()
        guard let built = PDFDocument(data: data as Data), let out = built.page(at: 0) else { return nil }
        out.retainBackingDocument(built)
        return out
    }
}
