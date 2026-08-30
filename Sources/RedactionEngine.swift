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

    /// How a marked region is destroyed: blackout = classic redaction box; erase = whiteout —
    /// the region reads as blank paper (logo/address removal). Both rasterize the page, so the
    /// removal is real either way; only the paint differs.
    /// Blackout keeps a deliberate solid-black bar — that is the legal convention and it must
    /// stay visible. Erase is cosmetic removal, so it paints the SURROUNDING background colour
    /// sampled from the rendered page (white paper stays white; a black header bar stays black)
    /// and the removal reads as blank space rather than a white sticker.
    enum Style { case blackout, erase
        var fill: NSColor { self == .blackout ? .black : .white }
        var samplesBackground: Bool { self == .erase }
    }

    /// Write `doc` to `url` with the given redactions applied (page index → rects in page space).
    /// Pass an empty map to get "Clean for Sharing": everything flattened, metadata dropped.
    static func apply(_ doc: PDFDocument, redactions: [Int: [CGRect]], style: Style = .blackout, to url: URL) -> Bool {
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
                if let cg = rasterized(page: page, blackout: rects, fill: style.fill,
                                       sampleBackground: style.samplesBackground) {
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

    /// A pixel-backed replacement for `page` with the regions destroyed — the in-place
    /// Erase path. Same rasterize discipline as apply(); the caller swaps it into the live
    /// document (undoable via page identity) and autosave persists it.
    static func destroyedPage(_ page: PDFPage, regions: [CGRect], style: Style) -> PDFPage? {
        // Retry a blank raster before using it: see contentSignal — page rendering is racy, and
        // baking a transiently-empty render into the document is exactly how pages went blank.
        var img = rasterized(page: page, blackout: regions, fill: style.fill,
                             sampleBackground: style.samplesBackground)
        if img != nil, contentSignal(of: page, excluding: regions) > 200 {
            for _ in 0..<2 where rasterIsBlank(img!) {
                img = rasterized(page: page, blackout: regions, fill: style.fill,
                                 sampleBackground: style.samplesBackground)
            }
        }
        guard let img else { return nil }
        var box = page.bounds(for: .mediaBox)
        box.origin = .zero
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
        ctx.beginPDFPage(info)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(img, in: box)
        ctx.restoreGState()
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    /// How much ink a page carries outside the regions being changed. This is the check that
    /// was missing: every destructive operation verified that the TARGET was gone, and none
    /// verified that THE REST OF THE PAGE SURVIVED — so a replacement page that came back
    /// completely blank passed as a success and was written to the user's file.
    ///
    /// Sampled, not exact: we only need "did the page's content collapse", not a pixel count.
    static func inkLevel(of page: PDFPage, excluding: [CGRect] = []) -> Int {
        let box = page.bounds(for: .mediaBox)
        guard box.width >= 1, box.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(box.width),
                                         pixelsHigh: Int(box.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return -1 }
        let cg = gctx.cgContext
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(origin: .zero, size: box.size))
        cg.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: cg)
        var n = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                let pt = CGPoint(x: box.origin.x + CGFloat(x),
                                 y: box.origin.y + CGFloat(rep.pixelsHigh - 1 - y))
                if excluding.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(pt) }) { continue }
                if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.98 { n += 1 }
            }
        }
        return n
    }

    /// 🧨 Rendering a PDF page is NOT deterministic. The same page, same file, same code has
    /// been observed returning a fully blank raster one moment and 8017 inked pixels the next —
    /// a font/resource loading race inside PDFKit/CoreGraphics. That is what produced blank
    /// pages in saved documents: an operation rasterized during a blank moment and persisted it.
    ///
    /// So a zero is never trusted on a page that demonstrably HAS content: re-render before
    /// believing it. Cheap, because it only happens when the first read looks empty.
    static func contentSignal(of page: PDFPage, excluding: [CGRect] = []) -> Int {
        var ink = inkLevel(of: page, excluding: excluding)
        guard ink <= 200 else { return ink }
        let hasText = !((page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let hasImages = !ImageHitEngine.images(on: page).isEmpty
        guard hasText || hasImages else { return ink }   // genuinely an empty page
        for _ in 0..<2 {
            ink = max(ink, inkLevel(of: page, excluding: excluding))
            if ink > 200 { break }
        }
        return ink
    }

    /// True when `replacement` still carries the content `original` had outside `regions`.
    /// A page that had content and comes back empty is a failed operation, never a success.
    static func preservesContent(original: PDFPage, replacement: PDFPage, regions: [CGRect]) -> Bool {
        let before = contentSignal(of: original, excluding: regions)
        guard before > 200 else { return true }        // page was already near-blank; nothing to lose
        let after = contentSignal(of: replacement, excluding: regions)
        return after >= before / 2
    }

    /// Is this rendered page image essentially empty?
    private static func rasterIsBlank(_ img: CGImage) -> Bool {
        guard let rep = NSBitmapImageRep(cgImage: img) as NSBitmapImageRep? else { return false }
        var n = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
                if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.98 {
                    n += 1
                    if n > 50 { return false }
                }
            }
        }
        return true
    }

    /// Adversarial check of an APPLIED file. Returns human-readable issues; empty == verified.
    /// `checkMetadata` belongs to the EXPORT path, which builds a fresh context and drops the
    /// /Info dict by construction. An in-place redaction is an edit of the user's own document
    /// and keeps its metadata on purpose — sanitising that is Clean for Sharing's job — so the
    /// in-place caller passes false rather than reporting a failure it does not mean.
    static func verify(outputURL: URL, redactedPages: [Int], forbiddenTerms: [String],
                       checkMetadata: Bool = true) -> [String] {
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
        if checkMetadata {
            let attrs = doc.documentAttributes ?? [:]
            for key: PDFDocumentAttribute in [.titleAttribute, .authorAttribute, .subjectAttribute,
                                              .keywordsAttribute, .creatorAttribute] {
                if let v = attrs[key] { issues.append("Metadata survived: \(key.rawValue) = \(v)") }
            }
        }
        return issues
    }

    // MARK: - Internals

    // Render the page to a JPEG-backed CGImage with the redaction rects filled solid black.
    // Redaction overlays and stamps are handled explicitly so nothing depends on custom
    // annotation subclasses drawing themselves through page.draw.
    private static func rasterized(page: PDFPage, blackout: [CGRect], fill: NSColor = .black,
                                   sampleBackground: Bool = false) -> CGImage? {
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
        let marks = page.overlayAnnotations
        (overlays + stamps + marks).forEach { page.removeAnnotation($0) }
        page.draw(with: .mediaBox, to: cg)
        for s in stamps {
            if let img = s.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                cg.draw(img, in: s.bounds)
            }
            page.addAnnotation(s)
        }
        // Watermark/Bates are page content, not review chatter — they belong in these outputs.
        for m in marks {
            cg.saveGState()
            m.drawInto(cg, pageBox: page.bounds(for: .mediaBox))
            cg.restoreGState()
            page.addAnnotation(m)
        }
        overlays.forEach { page.addAnnotation($0) }   // keep the on-screen doc intact

        // Sample BEFORE painting: the bitmap currently holds the rendered page, so the ring
        // just outside each region is the real background behind it.
        let fills: [NSColor] = blackout.map { r in
            guard sampleBackground else { return fill }
            return backgroundColor(around: r, in: rep, pageBox: box, scale: rasterScale) ?? fill
        }
        for (r, c) in zip(blackout, fills) {
            cg.setFillColor(c.cgColor)
            cg.fill(r)
        }
        cg.restoreGState()

        // JPEG round-trip keeps the embedded image (and the file) a sane size.
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]),
              let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Median colour of a ring of pixels just outside `rect`, read from the already-rendered
    /// page bitmap. Returns nil when the ring lands entirely off-page (a region covering the
    /// whole sheet), so the caller keeps its default rather than inventing a colour.
    ///
    /// Median, not mean: averaging a ring that straddles a black bar and white paper yields grey,
    /// which matches NEITHER side. The median picks a colour that actually occurs on the page.
    /// This is PAINT sampled from the page, never reconstruction — Jack does not invent content.
    private static func backgroundColor(around rect: CGRect, in rep: NSBitmapImageRep,
                                        pageBox: CGRect, scale: CGFloat) -> NSColor? {
        let inset: CGFloat = 3            // pixels outside the edge
        let perSide = 16
        // Page space → bitmap pixels. Row 0 of an NSBitmapImageRep is the TOP of the image,
        // while the page's origin is bottom-left — hence the y flip.
        func px(_ p: CGPoint) -> (Int, Int) {
            (Int(((p.x - pageBox.origin.x) * scale).rounded()),
             rep.pixelsHigh - 1 - Int(((p.y - pageBox.origin.y) * scale).rounded()))
        }
        var samples: [NSColor] = []
        let outset = rect.insetBy(dx: -inset / scale, dy: -inset / scale)
        for i in 0..<perSide {
            let t = CGFloat(i) / CGFloat(max(1, perSide - 1))
            let candidates = [
                CGPoint(x: outset.minX + outset.width * t, y: outset.maxY),   // above
                CGPoint(x: outset.minX + outset.width * t, y: outset.minY),   // below
                CGPoint(x: outset.minX, y: outset.minY + outset.height * t),  // left
                CGPoint(x: outset.maxX, y: outset.minY + outset.height * t)   // right
            ]
            for c in candidates {
                let (x, y) = px(c)
                guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
                      let col = rep.colorAt(x: x, y: y) else { continue }
                samples.append(col)
            }
        }
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted { $0.brightnessComponent < $1.brightnessComponent }
        return sorted[sorted.count / 2]
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
        let marks = page.overlayAnnotations
        marks.forEach { page.removeAnnotation($0) }
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
        for m in marks {
            ctx.saveGState()
            m.drawInto(ctx, pageBox: page.bounds(for: .mediaBox))
            ctx.restoreGState()
            page.addAnnotation(m)
        }
    }
}
