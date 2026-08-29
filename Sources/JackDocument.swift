// v2.0: Jack adopts the native document architecture — autosave-in-place, Versions,
// Duplicate, and the system title-bar popover (Name/Tags/Where) come from NSDocument.
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

@objc(JackDocument)
final class JackDocument: NSDocument {
    var pdf: PDFDocument?

    override class var autosavesInPlace: Bool { true }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

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
        return outIndex > 0 ? out : nil
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
