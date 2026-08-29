// True redaction, UI-free so the kill-path is testable headlessly.
//
// The industry failure mode is COSMETIC redaction: a black box drawn over text that is still
// extractable underneath. Jack never does that. apply() rasterizes every page that carries a
// redaction — the page's text objects cease to exist in the output — then paints solid black
// over the marked regions, and drops all document metadata by construction (fresh CGPDFContext).
// verify() then attacks the output the way an adversary would: extract text from redacted
// pages, search the whole document for the forbidden terms, and read back the metadata.
// A page with no redactions passes through as vectors (flattened, stamps burned in).
import AppKit
import PDFKit

enum RedactionEngine {

    static let rasterScale: CGFloat = 4.0   // 288 DPI — text-legible, size-sane
    static let jpegQuality: CGFloat = 0.8

    /// Write `doc` to `url` with the given redactions applied (page index → rects in page space).
    /// Pass an empty map to get "Clean for Sharing": everything flattened, metadata dropped.
    static func apply(_ doc: PDFDocument, redactions: [Int: [CGRect]], to url: URL) -> Bool {
        guard let firstPage = doc.page(at: 0) else { return false }
        var firstBox = firstPage.bounds(for: .mediaBox)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return false }

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)

            if let rects = redactions[i], !rects.isEmpty {
                // Kill path: page becomes pixels; the black is painted into the pixels.
                if let cg = rasterized(page: page, blackout: rects) {
                    ctx.saveGState()
                    ctx.interpolationQuality = .high
                    ctx.draw(cg, in: box)
                    ctx.restoreGState()
                }
            } else {
                drawFlattened(page, into: ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return true
    }

    /// Adversarial check of an APPLIED file. Returns human-readable issues; empty == verified.
    static func verify(outputURL: URL, redactedPages: [Int], forbiddenTerms: [String]) -> [String] {
        guard let doc = PDFDocument(url: outputURL) else { return ["Couldn’t reopen the output file."] }
        var issues: [String] = []

        for i in redactedPages {
            let text = (doc.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                issues.append("Page \(i + 1) still carries \(text.count) recoverable character(s).")
            }
        }
        for term in forbiddenTerms where !term.isEmpty {
            if !doc.findString(term, withOptions: [.caseInsensitive]).isEmpty {
                issues.append("“\(term)” is still findable in the document.")
            }
        }
        let attrs = doc.documentAttributes ?? [:]
        for key: PDFDocumentAttribute in [.titleAttribute, .authorAttribute, .subjectAttribute,
                                          .keywordsAttribute, .creatorAttribute] {
            if let v = attrs[key] { issues.append("Metadata survived: \(key.rawValue) = \(v)") }
        }
        return issues
    }

    // MARK: - Internals

    // Render the page to a JPEG-backed CGImage with the redaction rects filled solid black.
    // Redaction overlays and stamps are handled explicitly so nothing depends on custom
    // annotation subclasses drawing themselves through page.draw.
    private static func rasterized(page: PDFPage, blackout: [CGRect]) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let w = Int(box.width * rasterScale), h = Int(box.height * rasterScale)
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = gctx.cgContext

        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        cg.saveGState()
        cg.scaleBy(x: rasterScale, y: rasterScale)
        cg.translateBy(x: -box.origin.x, y: -box.origin.y)

        // Draw content without overlay annotations, then burn stamps, then paint the black.
        let overlays = page.annotations.filter {
            $0 is RedactionAnnotation || $0 is CommentBadgeAnnotation || $0.type == "Text"
        }
        let stamps = page.annotations.compactMap { $0 as? ImageStampAnnotation }
        (overlays + stamps).forEach { page.removeAnnotation($0) }
        page.draw(with: .mediaBox, to: cg)
        for s in stamps {
            if let img = s.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                cg.draw(img, in: s.bounds)
            }
            page.addAnnotation(s)
        }
        overlays.forEach { page.addAnnotation($0) }   // keep the on-screen doc intact

        cg.setFillColor(NSColor.black.cgColor)
        for r in blackout { cg.fill(r) }
        cg.restoreGState()

        // JPEG round-trip keeps the embedded image (and the file) a sane size.
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]),
              let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // Vector passthrough for clean pages: burn stamps, keep everything else as drawn.
    // Pending redaction overlays must never bake in as cosmetic boxes; comment notes are
    // review chatter and a "clean"/redacted deliverable drops them.
    private static func drawFlattened(_ page: PDFPage, into ctx: CGContext) {
        let overlays = page.annotations.filter {
            $0 is RedactionAnnotation || $0 is CommentBadgeAnnotation || $0.type == "Text"
        }
        overlays.forEach { page.removeAnnotation($0) }
        defer { overlays.forEach { page.addAnnotation($0) } }
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
            page.addAnnotation(s)
        }
    }
}
