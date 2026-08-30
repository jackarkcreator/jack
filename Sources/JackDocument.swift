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
final class JackDocument: NSDocument {
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

    /// True while the open file is still someone else's untouched original.
    var protectsOriginal: Bool { fileURL != nil && !isJackProduced && !hasSavedCopy }

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
        blank.insert(PDFPage(), at: 0)
        pdf = blank
    }

    override func read(from url: URL, ofType typeName: String) throws {
        guard let doc = PDFDocument(url: url) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                          userInfo: [NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” couldn’t be read as a PDF."])
        }
        pdf = doc
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
        guard let live = pdf,
              let out = JackDocument.buildPersistedDocument(from: live),
              let data = out.dataRepresentation() else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn’t serialize the PDF."])
        }
        // The fresh-document rebuild drops /AcroForm (fields go dead in Acrobat/Chrome)
        // and loses radio /V + /AS. Repair both at the byte level; no-op for widget-free docs.
        guard FormFieldEngine.hasWidgets(live) else { return data }
        return AcroFormFixup.fix(data: data, radioAsserts: FormFieldEngine.radioAsserts(from: live))
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
        guard protectsOriginal, let current = fileURL else {
            super.save(sender)
            return
        }
        pendingCopyName = current.deletingPathExtension().lastPathComponent + "-edited.pdf"
        saveAs(sender)
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
            }
            completionHandler(error)
        }
    }

    // NSDocument posts nothing when the edited flag flips; the window chrome needs to know.
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        postDirtyChanged()
    }

    private func postDirtyChanged() {
        NotificationCenter.default.post(name: .jackDocumentDirtyChanged, object: self)
    }

    // MARK: - Persistence builder

    static func buildPersistedDocument(from live: PDFDocument) -> PDFDocument? {
        let out = PDFDocument()
        var outIndex = 0
        for i in 0..<live.pageCount {
            guard let page = live.page(at: i) else { continue }
            let hasStamps = page.annotations.contains { $0 is ImageStampAnnotation }
            let persisted: PDFPage?
            if hasStamps {
                persisted = flattenedCopy(of: page)
            } else {
                persisted = page.copy() as? PDFPage
            }
            guard let p = persisted else { continue }

            // Ephemeral overlays never reach disk; badges convert to standard notes.
            for ann in p.annotations {
                if ann is RedactionAnnotation { p.removeAnnotation(ann) }
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
    private static func flattenedCopy(of page: PDFPage) -> PDFPage? {
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
        ctx.saveGState()
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
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
        return PDFDocument(data: data as Data)?.page(at: 0)
    }
}
