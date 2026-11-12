// Save as Word — turn a PDF into an editable Word document, entirely on this Mac.
//
// The honest scope (2026-11-11, reopened by Luis after a scanned contract came in for editing):
//   • Text PDFs are read from their text layer; scans are read twice with Vision (with and
//     without language correction). Words the two readings disagree on, or that contain
//     characters no document uses, are highlighted yellow in Word — never silently guessed.
//   • Layout is rebuilt, not traced: paragraphs, numbered / lettered items with hanging
//     indents, centered blocks, bold and underline (from ink weight and rules on the page),
//     fill-in lines, checkboxes (real Word checkboxes), a repeated letterhead (one image in
//     the header) and "N of M" page numbers (a live footer field).
//   • Handwriting is never copied. A signature becomes a placeholder line saying so.
//   • Tables and multi-column pages are REFUSED with a reason rather than mangled.
//   • Before the file is kept it is reopened and every written word must read back in order.
import AppKit
import ImageIO
import PDFKit
import Vision

enum WordExportEngine {

    struct Options {
        var matchPages = true          // page breaks where the PDF's pages break
        var keepLetterhead = true      // repeated top-of-page block → one header image
        var markUncertain = true       // yellow highlight on words to double-check
    }

    struct Report {
        var pages = 0
        var scannedPages = 0
        var words = 0
        var agreedWords = 0
        var uncertainWords = 0
        var leftOutMarks = 0
        var signaturePlaceholders = 0
        var checkboxes = 0
        var checkedBoxes = 0
        var letterhead = false
        var pageNumbers = false
        var declaredPageTotal: Int? = nil
        var readback: Double = 0
        var debug: [String] = []

        var missingPages: ClosedRange<Int>? {
            guard let t = declaredPageTotal, t > pages, t - pages < 500 else { return nil }
            return (pages + 1)...t
        }
        var agreement: Double { words == 0 ? 1 : Double(agreedWords) / Double(words) }

        var summary: String {
            var s = "\(pages) page(s), \(words) words"
            s += scannedPages > 0
                ? String(format: " · %.1f%% read the same twice", agreement * 100)
                : String(format: " · %.1f%% match the PDF's own text", agreement * 100)
            if uncertainWords > 0 { s += " · \(uncertainWords) to double-check" }
            if checkboxes > 0 { s += " · \(checkboxes) checkbox(es), \(checkedBoxes) ticked" }
            if signaturePlaceholders > 0 { s += " · \(signaturePlaceholders) signature(s) left out" }
            if leftOutMarks > signaturePlaceholders { s += " · \(leftOutMarks - signaturePlaceholders) unreadable mark(s) left out" }
            if let m = missingPages { s += " · footers say \(m.upperBound) pages, pages \(m.lowerBound)–\(m.upperBound) not in this PDF" }
            s += String(format: " · read-back %.1f%%", readback * 100)
            return s
        }
    }

    enum ExportError: LocalizedError {
        case refused(String, text: String)     // the reason, and every word read (for Copy Text)
        case noText
        case writeFailed
        case verifyFailed(Double)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .refused(let why, _): return why
            case .cancelled: return "Stopped. Nothing was saved."
            case .noText: return "Jack couldn’t find any readable text in this PDF."
            case .writeFailed: return "The Word document couldn’t be written."
            case .verifyFailed(let r):
                return String(format: "The Word document didn’t check out against the PDF (%.0f%% of words read back), so Jack didn’t keep it.", r * 100)
            }
        }
    }

    /// Where the .docx lands: beside the PDF, never clobbering anything.
    static func outputURL(for source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent(base + ".docx")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n).docx")
            n += 1
        }
        return candidate
    }

    // MARK: - Model

    final class Item {
        enum Kind { case word, checkbox, blank, note }
        var kind: Kind
        var text: String
        var x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat   // points, TOP-LEFT origin
        var bold = false
        var underline = false
        var uncertain = false
        var checked = false
        var stroke: CGFloat = 0          // ink stroke width / height (scans)

        init(_ kind: Kind, _ text: String, _ x0: CGFloat, _ x1: CGFloat, _ y0: CGFloat, _ y1: CGFloat) {
            self.kind = kind; self.text = text; self.x0 = x0; self.x1 = x1; self.y0 = y0; self.y1 = y1
        }
        var h: CGFloat { y1 - y0 }
        var cy: CGFloat { (y0 + y1) / 2 }
    }

    struct Line {
        var text: String
        var x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat
        var confidence: Float
        var items: [Item]
    }

    struct Rule { var x0: CGFloat; var x1: CGFloat; var y: CGFloat }

    final class PageData {
        let index: Int
        let width: CGFloat, height: CGFloat
        var lines: [Line] = []
        var extras: [Item] = []
        var rules: [Rule] = []
        var dropped: [Line] = []
        var isScan = false
        var gray: GrayImage?
        init(index: Int, width: CGFloat, height: CGFloat) { self.index = index; self.width = width; self.height = height }
    }

    struct GrayImage {
        let w: Int, h: Int
        let scale: CGFloat
        let px: [UInt8]
        let cg: CGImage
        @inline(__always) func dark(_ c: Int, _ r: Int) -> Bool { px[r * w + c] < 150 }
    }

    static let renderScale: CGFloat = 4.0     // 288 dpi, same as Make Searchable

    // MARK: - Entry point

    /// Convert `doc` to a .docx at `url`. Throws `refused` / `noText` / `verifyFailed`; on any
    /// throw nothing is left at `url`. `progress` gets (pageIndex, pageCount) while reading.
    static func export(_ doc: PDFDocument, to url: URL, title: String, options: Options = Options(),
                       progress: ((Int, Int) -> Void)? = nil, cancelled: (() -> Bool)? = nil) throws -> Report {
        var report = Report()
        report.pages = doc.pageCount
        guard doc.pageCount > 0 else { throw ExportError.noText }
        WordDump.begin(pageCount: doc.pageCount)

        // 1. Read every page.
        var pages: [PageData] = []
        for i in 0..<doc.pageCount {
            progress?(i, doc.pageCount)
            if cancelled?() == true { throw ExportError.cancelled }
            guard let page = doc.page(at: i) else { continue }
            let pd = read(page, index: i, report: &report)
            pages.append(pd)
        }
        let allWords = pages.flatMap { $0.lines.flatMap { $0.items } }.filter { $0.kind == .word }
        guard allWords.count >= 3 else { throw ExportError.noText }

        // 2. Letterhead and page-number footer.
        let hf = detectHeaderFooter(pages, report: &report)

        // 3. Ink: underline / fill-in lines, bold (scans), checkboxes.
        for p in pages { decorate(p, headerBottom: options.keepLetterhead ? hf.headerBottom[p.index] : nil) }

        // 4. Rows, refusal checks, paragraphs.
        var rowsByPage: [[Row]] = []
        for p in pages { rowsByPage.append(buildRows(p, hf: hf, keepLetterhead: options.keepLetterhead, report: &report)) }
        if let why = refusal(rowsByPage, pages) {
            let text = rowsByPage.map { rows in
                rows.map { r in r.words.map { $0.text }.joined(separator: " ") }.filter { !$0.isEmpty }.joined(separator: "\n")
            }.joined(separator: "\n\n")
            throw ExportError.refused(why, text: text)
        }
        if cancelled?() == true { throw ExportError.cancelled }
        progress?(doc.pageCount, doc.pageCount)

        var model = DocxModel()
        model.title = title
        let geo = geometry(pages, rowsByPage)
        model.pageWidth = pages[0].width
        model.pageHeight = pages[0].height
        model.marginLeft = geo.left
        model.marginRight = max(36, pages[0].width - geo.right)
        model.marginBottom = 54
        model.baseSize = geo.baseSize
        model.baseFont = geo.font
        report.debug.append(String(format: "geometry: left %.1f right %.1f bodyH %.2f base %.1fpt font %@", geo.left, geo.right, geo.bodyH, geo.baseSize, geo.font))

        if options.keepLetterhead, let lh = hf.letterhead, let png = letterheadPNG(doc, lh) {
            model.headerPNG = png.data
            model.headerSize = png.size
            model.headerDistance = max(18, lh.rect.minY)
            model.headerOffsetX = lh.rect.minX - geo.left
            model.marginTop = max(model.headerDistance + png.size.height + 10, geo.top)
            report.letterhead = true
        } else {
            model.marginTop = max(36, geo.top)
        }
        model.pageNumberFooter = hf.pageNumbers
        report.pageNumbers = hf.pageNumbers

        var written: [String] = []
        model.paragraphs = paragraphs(rowsByPage, pages: pages, geo: geo, topY: model.marginTop,
                                      options: options, report: &report, written: &written)

        // 5. Write, then prove it: reopen and require every written word back, in order.
        do { try DocxWriter.write(model, to: url) } catch { throw ExportError.writeFailed }
        let back = readBack(url)
        report.readback = inOrderRatio(written, back ?? [])
        if report.readback < 0.985 {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.verifyFailed(report.readback)
        }
        return report
    }

    // MARK: - 1. Reading

    static func read(_ page: PDFPage, index: Int, report: inout Report) -> PageData {
        let box = page.bounds(for: .mediaBox)
        let pd = PageData(index: index, width: box.width, height: box.height)
        pd.gray = render(page)
        let existing = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Every page is read from its rendered image (one layout path for all PDFs). The second,
        // independent reading is the PDF's own text layer when it has a trustworthy one, or a
        // second Vision pass without language correction when it's a scan.
        let textLayer = existing.count > 20 && !isScanPage(page)
        guard var g = pd.gray else { return pd }
        let dump = WordDump.dir == nil ? nil : WordDump.Page(index: index, page: page, box: box, rendered: g)   // debug only
        if !textLayer {
            pd.isScan = true; report.scannedPages += 1
            // A scan fed in at an angle: straighten it before anything reads it, or neighbouring
            // lines drift into each other and their words get woven together. Every word would
            // still read right, so the two readings could not catch it.
            let skew = estimateSkew(g)
            dump?.skew = skew
            if abs(skew) >= 0.15, let straight = rotated(g, degrees: skew) {
                g = straight
                pd.gray = straight
                dump?.deskewed = straight
                report.debug.append(String(format: "p%d deskewed %.2f° (left %.2f°)", index + 1, skew, estimateSkew(straight)))
            }
        }
        let first = recognize(g, W: box.width, H: box.height, correction: true)
        dump?.first = WordDump.lastRecognized
        var kept: [Line] = []
        for l in first {
            // Handwriting and smudges come back at low confidence: never copy them.
            if l.confidence < 0.35 || l.text.trimmingCharacters(in: .whitespaces).isEmpty { pd.dropped.append(l); continue }
            kept.append(l)
        }
        let a = kept.flatMap { $0.items }
        let second: [String] = textLayer
            ? existing.components(separatedBy: .whitespacesAndNewlines).map { norm($0) }.filter { !$0.isEmpty }
            : recognize(g, W: box.width, H: box.height, correction: false).filter { $0.confidence >= 0.35 }.flatMap { $0.items }.map { norm($0.text) }
        if !textLayer { dump?.second = WordDump.lastRecognized }
        dump?.write()
        let agreed = lcsMatches(a.map { norm($0.text) }, second)
        for (i, w) in a.enumerated() {
            let n = norm(w.text)
            if (!agreed.contains(i) && n.count > 1) || looksGarbled(w.text) { w.uncertain = true }
        }
        pd.lines = kept
        report.debug.append("p\(index + 1) \(textLayer ? "text" : "scan"): \(first.count) lines, dropped \(pd.dropped.count)")
        return pd
    }

    /// A page whose content is one page-sized picture is a scan, even when a scanner put an
    /// (often poor) OCR text layer under it — Jack reads those pages itself.
    static func isScanPage(_ page: PDFPage) -> Bool {
        guard let ref = page.pageRef, let dict = ref.dictionary else { return false }
        var res: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let r = res else { return false }
        var xo: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(r, "XObject", &xo), let x = xo else { return false }
        let box = page.bounds(for: .mediaBox)
        var found = false
        CGPDFDictionaryApplyBlock(x, { _, obj, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(obj, .stream, &stream), let st = stream, let sd = CGPDFStreamGetDictionary(st) else { return true }
            var name: UnsafePointer<CChar>?
            var w: CGPDFInteger = 0, h: CGPDFInteger = 0
            if CGPDFDictionaryGetName(sd, "Subtype", &name), let n = name, String(cString: n) == "Image",
               CGPDFDictionaryGetInteger(sd, "Width", &w), CGPDFDictionaryGetInteger(sd, "Height", &h), h > 0 {
                let ar = Double(w) / Double(h), pr = Double(box.width / max(1, box.height))
                if Double(w) >= Double(box.width) * 1.4 && abs(ar - pr) < 0.08 { found = true }
            }
            return !found
        }, nil)
        return found
    }

    static func render(_ page: PDFPage) -> GrayImage? {
        let box = page.bounds(for: .mediaBox)
        let s = renderScale
        let w = Int(box.width * s), h = Int(box.height * s)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        guard let cg = ctx.makeImage(), let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        var px = [UInt8](repeating: 255, count: w * h)
        px.withUnsafeMutableBytes { dst in
            for r in 0..<h { memcpy(dst.baseAddress! + r * w, data + r * bpr, w) }   // row 0 = top of page
        }
        return GrayImage(w: w, h: h, scale: s, px: px, cg: cg)
    }

    /// The page's tilt in degrees (positive = text lines fall to the right), from a projection
    /// profile: lines of text make the sharpest row histogram when they are counted along their
    /// own slope. Returns 0 when there is too little ink or no clear peak (a photo, a blank page).
    static func estimateSkew(_ g: GrayImage) -> CGFloat {
        let step = 3
        var xs: [Float] = [], ys: [Float] = []
        for r in stride(from: 0, to: g.h, by: step) {
            let base = r * g.w
            for c in stride(from: 0, to: g.w, by: step) where g.px[base + c] < 150 {
                xs.append(Float(c)); ys.append(Float(r))
            }
        }
        guard xs.count > 1500 else { return 0 }
        // One bin per sampled row. A bin height that is not the sampling step aliases: at exactly
        // 0° some bins are always empty, which inflates the score there and hides tilts under ~1°.
        let binH = Float(step)
        let off = Float(g.w) * 0.08                          // room for a 4° slope
        let nb = Int((Float(g.h) + 2 * off) / binH) + 2
        var bins = [Int32](repeating: 0, count: nb)
        func score(_ deg: Float) -> Double {
            let t = tanf(deg * .pi / 180)
            for i in bins.indices { bins[i] = 0 }
            for i in xs.indices {
                let b = Int((ys[i] - xs[i] * t + off) / binH)
                if b >= 0 && b < nb { bins[b] += 1 }
            }
            var s = 0.0
            for v in bins { s += Double(v) * Double(v) }
            return s
        }
        let flat = score(0)
        var best: Float = 0, bestScore = flat
        for k in -40...40 where k != 0 {
            let d = Float(k) * 0.1, sc = score(d)
            if sc > bestScore { bestScore = sc; best = d }
        }
        var fine = best
        for k in -9...9 where k != 0 {
            let d = best + Float(k) * 0.01, sc = score(d)
            if sc > bestScore { bestScore = sc; fine = d }
        }
        if ProcessInfo.processInfo.environment["JACK_WORD_DEBUG_SKEW"] != nil {
            print(String(format: "skew: points %d best %.2f° ratio %.4f", xs.count, fine, bestScore / flat))
        }
        guard bestScore > flat * 1.03 else { return 0 }
        return CGFloat(fine)
    }

    /// `g` turned by `degrees` (counter-clockwise as seen) about its centre, on white.
    static func rotated(_ g: GrayImage, degrees: CGFloat) -> GrayImage? {
        let w = g.w, h = g.h
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: degrees * .pi / 180)
        ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
        ctx.draw(g.cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let cg = ctx.makeImage(), let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        var px = [UInt8](repeating: 255, count: w * h)
        px.withUnsafeMutableBytes { dst in
            for r in 0..<h { memcpy(dst.baseAddress! + r * w, data + r * bpr, w) }   // row 0 = top
        }
        return GrayImage(w: w, h: h, scale: g.scale, px: px, cg: cg)
    }

    static func recognize(_ g: GrayImage, W: CGFloat, H: CGFloat, correction: Bool) -> [Line] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = correction
        req.recognitionLanguages = ["en-US", "es-MX"]
        let handler = VNImageRequestHandler(cgImage: g.cg, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results else { return [] }
        var lines: [Line] = []
        let wordRx = try! NSRegularExpression(pattern: "\\S+")
        for o in obs {
            guard let cand = o.topCandidates(1).first else { continue }
            let text = cand.string
            let b = o.boundingBox
            let lx0 = b.minX * W, lx1 = b.maxX * W, ly0 = (1 - b.maxY) * H, ly1 = (1 - b.minY) * H
            var items: [Item] = []
            let ns = text as NSString
            let ms = wordRx.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for (k, m) in ms.enumerated() {
                let wt = ns.substring(with: m.range)
                var x0 = lx0 + (lx1 - lx0) * CGFloat(m.range.location) / CGFloat(max(1, ns.length))
                var x1 = lx0 + (lx1 - lx0) * CGFloat(m.range.location + m.range.length) / CGFloat(max(1, ns.length))
                var y0 = ly0, y1 = ly1
                if let r = Range(m.range, in: text), let wb = try? cand.boundingBox(for: r) {
                    let bb = wb.boundingBox
                    if bb.width > 0 && bb.height > 0 {
                        x0 = bb.minX * W; x1 = bb.maxX * W; y0 = (1 - bb.maxY) * H; y1 = (1 - bb.minY) * H
                    }
                }
                _ = k
                items.append(Item(.word, wt, x0, x1, y0, y1))
            }
            lines.append(Line(text: text, x0: lx0, x1: lx1, y0: ly0, y1: ly1, confidence: cand.confidence, items: items))
        }
        let unsorted = WordDump.dir == nil ? [] : lines   // debug only
        // Reading order: top to bottom, then left to right.
        lines.sort { abs($0.y0 - $1.y0) > min($0.y1 - $0.y0, $1.y1 - $1.y0) * 0.5 ? $0.y0 < $1.y0 : $0.x0 < $1.x0 }
        if WordDump.dir != nil { WordDump.lastRecognized = WordDump.recognized(unsorted, sorted: lines) }
        return lines
    }

    // MARK: - 2. Letterhead and footer

    struct HeaderFooter {
        var headerKeys: Set<String> = []
        var footerLineIDs: Set<String> = []        // "page:lineIndex" of page-number lines
        var headerBottom: [Int: CGFloat] = [:]     // per page, y below which the body starts
        var letterhead: (page: Int, rect: CGRect)? = nil
        var pageNumbers = false
    }

    static let pageNumberRx = try! NSRegularExpression(pattern: "^\\s*(page\\s*)?(\\d{1,4})\\s*(of|/)\\s*(\\d{1,4})?\\s*$", options: [.caseInsensitive])

    static func detectHeaderFooter(_ pages: [PageData], report: inout Report) -> HeaderFooter {
        var hf = HeaderFooter()
        // Page numbers ("4 of 16", "Page 2", "2/9") in the bottom band.
        for p in pages {
            for (li, l) in p.lines.enumerated() where l.y0 > p.height * 0.86 {
                let t = l.text as NSString
                if let m = pageNumberRx.firstMatch(in: l.text, range: NSRange(location: 0, length: t.length)) {
                    hf.footerLineIDs.insert("\(p.index):\(li)")
                    hf.pageNumbers = true
                    if m.range(at: 4).location != NSNotFound, let total = Int(t.substring(with: m.range(at: 4))) {
                        report.declaredPageTotal = max(report.declaredPageTotal ?? 0, total)
                    }
                }
            }
        }
        // Letterhead: top-band lines that repeat on at least half the pages (2+).
        guard pages.count >= 2 else { return hf }
        var counts: [String: Int] = [:]
        for p in pages {
            var seen = Set<String>()
            for l in p.lines where l.y1 < p.height * 0.17 {
                let k = headerKey(l.text)
                if k.count >= 3 { seen.insert(k) }
            }
            for k in seen { counts[k, default: 0] += 1 }
        }
        let need = max(2, Int((Double(pages.count) * 0.5).rounded(.up)))
        hf.headerKeys = Set(counts.filter { $0.value >= need }.map { $0.key })
        guard !hf.headerKeys.isEmpty else { return hf }
        for p in pages {
            let hl = p.lines.filter { $0.y1 < p.height * 0.17 && hf.headerKeys.contains(headerKey($0.text)) }
            guard let bottom = hl.map({ $0.y1 }).max() else { continue }
            hf.headerBottom[p.index] = bottom + 3
            if hf.letterhead == nil, let g = p.gray {
                // The letterhead block: every mark between the page top and the header text's bottom.
                if let r = inkBounds(g, in: CGRect(x: 0, y: 0, width: p.width, height: bottom + 3)) {
                    hf.letterhead = (p.index, r)
                }
            }
        }
        return hf
    }

    /// Bounding box (points) of the ink inside `rect` (points, top-left), ignoring a thin page edge.
    static func inkBounds(_ g: GrayImage, in rect: CGRect) -> CGRect? {
        let s = g.scale
        let edge = Int(6 * s)
        let c0 = max(edge, Int(rect.minX * s)), c1 = min(g.w - edge, Int(rect.maxX * s))
        let r0 = max(edge, Int(rect.minY * s)), r1 = min(g.h - edge, Int(rect.maxY * s))
        guard c1 > c0, r1 > r0 else { return nil }
        var minC = Int.max, maxC = -1, minR = Int.max, maxR = -1
        for r in r0..<r1 {
            var any = false
            for c in c0..<c1 where g.px[r * g.w + c] < 200 {
                any = true
                if c < minC { minC = c }
                if c > maxC { maxC = c }
            }
            if any { if r < minR { minR = r }; maxR = r }
        }
        guard maxC > minC, maxR > minR else { return nil }
        let pad: CGFloat = 2
        return CGRect(x: CGFloat(minC) / s - pad, y: CGFloat(minR) / s - pad,
                      width: CGFloat(maxC - minC) / s + pad * 2, height: CGFloat(maxR - minR) / s + pad * 2)
    }

    /// Render the letterhead block in colour and trim it — it becomes the header picture.
    static func letterheadPNG(_ doc: PDFDocument, _ lh: (page: Int, rect: CGRect)) -> (data: Data, size: CGSize)? {
        guard let page = doc.page(at: lh.page) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let s: CGFloat = 3
        let r = lh.rect
        let w = Int(r.width * s), h = Int(r.height * s)
        guard w > 4, h > 4,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: s, y: s)
        // Move the crop's top-left (top-left coords) to the context origin.
        ctx.translateBy(x: -r.minX - box.minX, y: -(box.height - r.maxY) - box.minY)
        page.draw(with: .mediaBox, to: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        // Paper is never pure white in a scan — lift near-white to white so the header sits clean.
        let rep = NSBitmapImageRep(cgImage: cg)
        if WordDump.dir != nil { WordDump.letterheadRaw(cg, rep: rep, page: lh.page, rect: r, w: w, h: h) }   // debug only
        if let p = rep.bitmapData, rep.bitsPerPixel == 32 {
            let n = rep.pixelsWide * rep.pixelsHigh
            for i in 0..<n {
                let o = i * 4
                let rr = p[o], gg = p[o + 1], bb = p[o + 2]
                if min(rr, gg, bb) > 196 && Int(max(rr, gg, bb)) - Int(min(rr, gg, bb)) < 34 { p[o] = 255; p[o + 1] = 255; p[o + 2] = 255 }
            }
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        if WordDump.dir != nil { WordDump.letterheadFinal(png, rep: rep) }   // debug only
        return (png, r.size)
    }

    // MARK: - 3. Ink: rules, underline, bold, checkboxes

    static func decorate(_ p: PageData, headerBottom: CGFloat?) {
        guard let g = p.gray else { return }
        let floorY = headerBottom ?? 0
        p.rules = findRules(g).filter { $0.y > floorY }
        let words = p.lines.flatMap { $0.items }

        // Checkboxes first, so a box OCR'd as a letter can be dropped.
        if p.isScan || true {
            for cb in findSquares(g) where cb.y0 > floorY {
                // A square made of a word's own lettering is a letter, not a box: the bowl of a bold
                // "o", "a" or "P" in a heading draws a closed outline, and strokes of two lines of
                // tight text can close one too. Either the word starts well before the square, or the
                // square is much shorter or much taller than the word it sits in (a real box is about
                // as tall as its label, even when Vision glues the tick onto the label).
                let bw = cb.x1 - cb.x0, bh = cb.y1 - cb.y0
                let inLettering = words.contains { w in
                    w.text.count > 2 && w.x0 < cb.x1 - bw * 0.5 && w.x1 > cb.x1 + 1
                        && min(w.y1, cb.y1) - max(w.y0, cb.y0) > min(bh, w.h) * 0.5
                        && (w.x0 < cb.x0 - max(2, bw * 0.3) || bh < w.h * 0.6 || bh > w.h * 1.6)
                }
                if inLettering { continue }
                // A real box sits on light paper. Light text on a dark band (a cover banner) turns
                // the gaps between letters into "outlines": the ring around them is mostly ink.
                let outer = CGRect(x: cb.x0 - 3, y: cb.y0 - 3, width: bw + 6, height: bh + 6)
                let outerArea = outer.width * outer.height, boxArea = bw * bh
                let ringInk = (inkFraction(g, outer) * Double(outerArea) - inkFraction(g, CGRect(x: cb.x0, y: cb.y0, width: bw, height: bh)) * Double(boxArea))
                    / Double(max(1, outerArea - boxArea))
                if ringInk > 0.45 { continue }      // measured: real boxes ≤ 0.36, banner gaps mostly 0.45–0.95
                // A real checkbox has its label right after it; logo shapes and frames don't.
                // (The label may start INSIDE the box: a tick that overshoots gets read as its first letter.)
                let labelled = words.contains { $0.x1 > cb.x1 + 4 && $0.x0 < cb.x1 + 40 && abs($0.cy - cb.cy) < max(cb.y1 - cb.y0, $0.h) }
                guard labelled else { continue }
                // Only a word level with the box (half its height overlapping): a title on the line
                // above a "☐ Individual" box is not its label, and lost its "I" as a "tick".
                for w in words where w.x0 < cb.x1 - 1 && w.x1 > cb.x1 + 4 && abs(w.cy - cb.cy) < max(cb.y1 - cb.y0, w.h)
                    && min(w.y1, cb.y1) - max(w.y0, cb.y0) > 0.5 * min(w.h, cb.y1 - cb.y0) {
                    // Strip the tick that Vision glued onto the label ("√Comprehensive", "VGeneral").
                    let tickish = Set("√✓✔/|\\VvJjIl1")
                    var t = Substring(w.text)
                    while let c = t.first, tickish.contains(c), t.count > 1, let nx = t.dropFirst().first, nx.isUppercase || !nx.isLetter { t = t.dropFirst() }
                    if t.count != w.text.count { w.text = String(t); w.x0 = cb.x1 + 1 }
                }
                p.extras.append(cb)
                if ProcessInfo.processInfo.environment["JACK_WORD_DEBUG_BOXES"] != nil {
                    let near = words.filter { abs($0.cy - cb.cy) < 10 && $0.x0 >= cb.x0 - 4 }.sorted { $0.x0 < $1.x0 }.prefix(3).map { $0.text }.joined(separator: " ")
                    print(String(format: "box p%d x %.0f-%.0f y %.0f-%.0f checked %d next: %@", p.index + 1, cb.x0, cb.x1, cb.y0, cb.y1, cb.checked ? 1 : 0, near))
                }
            }
            if !p.extras.isEmpty {
                for li in p.lines.indices {
                    p.lines[li].items.removeAll { w in
                        p.extras.contains { cb in overlap(w, cb) > 0.5 && w.text.count <= 2 }
                    }
                }
            }
        }

        // A checkbox's top and bottom edges are not rules.
        let boxes = p.extras.filter { $0.kind == .checkbox }
        p.rules.removeAll { r in boxes.contains { b in r.x0 > b.x0 - 3 && r.x1 < b.x1 + 3 && r.y > b.y0 - 2 && r.y < b.y1 + 2 } }

        // Underline: a rule just under a word, spanning most of it.
        var covered: [[(CGFloat, CGFloat)]] = Array(repeating: [], count: p.rules.count)
        for w in words {
            for (ri, r) in p.rules.enumerated() {
                let ov = min(w.x1, r.x1) - max(w.x0, r.x0)
                guard ov > (w.x1 - w.x0) * 0.6 else { continue }
                if r.y > w.y1 - w.h * 0.35 && r.y < w.y1 + w.h * 0.45 {
                    w.underline = true
                    covered[ri].append((w.x0, w.x1))
                }
            }
        }
        // What's left of each rule is a fill-in line.
        for (ri, r) in p.rules.enumerated() {
            let spans = covered[ri].sorted { $0.0 < $1.0 }
            var x = r.x0
            var pieces: [(CGFloat, CGFloat)] = []
            if let first = spans.first, let last = spans.last {
                if first.0 - r.x0 > 18 { pieces.append((r.x0, first.0)) }
                if r.x1 - last.1 > 18 { pieces.append((last.1, r.x1)) }
            } else if r.x1 - r.x0 > 18 {
                pieces.append((r.x0, r.x1))
            }
            _ = x
            for (a, b) in pieces {
                // Ink of a word sitting on the line means it's that word's underline, not a blank.
                let onIt = words.contains { w in min(w.x1, b) - max(w.x0, a) > 2 && r.y > w.y0 && r.y < w.y1 + w.h * 0.5 }
                if onIt { continue }
                let it = Item(.blank, "", a, b, r.y - 9, r.y)
                p.extras.append(it)
            }
        }

        // Bold (scans): ink stroke width relative to the page's typical stroke.
        do {
            for w in words { w.stroke = strokeRatio(g, w) }
            let vals = words.filter { $0.text.count >= 3 && $0.stroke > 0 }.map { $0.stroke }.sorted()
            if vals.count > 10 {
                let med = vals[vals.count / 2]
                for w in words where w.stroke > med * 1.32 && w.text.count >= 2 { w.bold = true }
                // Smooth: bold is a property of phrases, not of one letter group in a sentence.
                for li in p.lines.indices {
                    let its = p.lines[li].items
                    guard its.count >= 3 else { continue }
                    for k in 1..<(its.count - 1) where its[k].bold && !its[k - 1].bold && !its[k + 1].bold && !its[k].underline {
                        its[k].bold = false
                    }
                    for k in 1..<(its.count - 1) where !its[k].bold && its[k - 1].bold && its[k + 1].bold {
                        its[k].bold = true
                    }
                }
            }
        }
    }

    /// Long, thin, horizontal dark runs: underlines, fill-in lines, signature lines.
    static func findRules(_ g: GrayImage) -> [Rule] {
        let s = g.scale
        let minRun = Int(16 * s)
        let maxThick = Int(3.6 * s)
        struct Seg { var c0: Int; var c1: Int; var r0: Int; var r1: Int }
        var open: [Seg] = []
        var done: [Seg] = []
        for r in 0..<g.h {
            var runs: [(Int, Int)] = []
            var c = 0
            let base = r * g.w
            while c < g.w {
                if g.px[base + c] < 150 {
                    let start = c
                    var gap = 0
                    var end = c
                    while c < g.w {
                        if g.px[base + c] < 150 { end = c; gap = 0 } else { gap += 1; if gap > 3 { break } }
                        c += 1
                    }
                    if end - start >= minRun { runs.append((start, end)) }
                } else { c += 1 }
            }
            var next: [Seg] = []
            var used = Array(repeating: false, count: runs.count)
            for var sg in open {
                var extended = false
                for (k, run) in runs.enumerated() where !used[k] {
                    let ov = min(sg.c1, run.1) - max(sg.c0, run.0)
                    if ov > min(sg.c1 - sg.c0, run.1 - run.0) / 2 {
                        sg.c0 = min(sg.c0, run.0); sg.c1 = max(sg.c1, run.1); sg.r1 = r
                        used[k] = true; extended = true
                        break
                    }
                }
                if extended { next.append(sg) } else { done.append(sg) }
            }
            for (k, run) in runs.enumerated() where !used[k] { next.append(Seg(c0: run.0, c1: run.1, r0: r, r1: r)) }
            open = next
        }
        done.append(contentsOf: open)
        return done.filter { $0.r1 - $0.r0 + 1 <= maxThick }
            .map { Rule(x0: CGFloat($0.c0) / s, x1: CGFloat($0.c1) / s, y: CGFloat($0.r0 + $0.r1) / 2 / s) }
            .sorted { $0.y < $1.y }
    }

    /// Small squares (7–22 pt) drawn as outlines: Vision's rectangle detector, then an ink check
    /// for the tick inside.
    static func findCheckboxes(_ g: GrayImage, W: CGFloat, H: CGFloat) -> [Item] {
        let req = VNDetectRectanglesRequest()
        req.minimumAspectRatio = 0.72
        req.maximumAspectRatio = 1.0
        req.minimumSize = Float(6.5 / min(W, H))
        req.maximumObservations = 0
        req.quadratureTolerance = 12
        req.minimumConfidence = 0.4
        let handler = VNImageRequestHandler(cgImage: g.cg, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results else { return [] }
        var out: [Item] = []
        for o in obs {
            let b = o.boundingBox
            let x0 = b.minX * W, x1 = b.maxX * W, y0 = (1 - b.maxY) * H, y1 = (1 - b.minY) * H
            let w = x1 - x0, h = y1 - y0
            guard w >= 6.5, w <= 22, h >= 6.5, h <= 22, max(w, h) / min(w, h) < 1.35 else { continue }
            // Outline check: the border must be inked, otherwise this is a letter counter or a gap.
            let border = inkFraction(g, CGRect(x: x0, y: y0, width: w, height: max(1, h * 0.12)))
            guard border > 0.45 else { continue }
            let inner = inkFraction(g, CGRect(x: x0 + w * 0.25, y: y0 + h * 0.25, width: w * 0.5, height: h * 0.5))
            if out.contains(where: { abs($0.x0 - x0) < 4 && abs($0.y0 - y0) < 4 }) { continue }
            let it = Item(.checkbox, "", x0, x1, y0, y1)
            it.checked = inner > 0.14
            out.append(it)
        }
        return out
    }

    /// Checkboxes: two short horizontal edges of equal length, one a box-height above the other,
    /// joined by inked vertical sides. The tick inside decides checked.
    static func findSquares(_ g: GrayImage) -> [Item] {
        let s = g.scale
        let minRun = Int(6.5 * s), maxRun = Int(24 * s), maxThick = Int(3 * s)
        struct Seg { var c0: Int; var c1: Int; var r0: Int; var r1: Int }
        var open: [Seg] = [], done: [Seg] = []
        for r in 0..<g.h {
            var runs: [(Int, Int)] = []
            var c = 0
            let base = r * g.w
            while c < g.w {
                if g.px[base + c] < 150 {
                    let start = c
                    var gap = 0, end = c
                    while c < g.w {
                        if g.px[base + c] < 150 { end = c; gap = 0 } else { gap += 1; if gap > 1 { break } }
                        c += 1
                    }
                    let len = end - start
                    if len >= minRun && len <= maxRun { runs.append((start, end)) }
                } else { c += 1 }
            }
            var next: [Seg] = []
            var used = Array(repeating: false, count: runs.count)
            for var sg in open {
                var ext = false
                for (k, run) in runs.enumerated() where !used[k] && abs(run.0 - sg.c0) <= 3 && abs(run.1 - sg.c1) <= 3 {
                    sg.r1 = r; used[k] = true; ext = true; break
                }
                if ext { next.append(sg) } else { done.append(sg) }
            }
            for (k, run) in runs.enumerated() where !used[k] { next.append(Seg(c0: run.0, c1: run.1, r0: r, r1: r)) }
            open = next
        }
        done.append(contentsOf: open)
        let edges = done.filter { $0.r1 - $0.r0 + 1 <= maxThick }.sorted { $0.r0 < $1.r0 }
        var out: [Item] = []
        for (i, top) in edges.enumerated() {
            let len = top.c1 - top.c0
            for bot in edges[(i + 1)...] {
                let dy = bot.r0 - top.r0
                if dy > Int(Double(len) * 1.4) { break }
                guard dy >= Int(Double(len) * 0.7), abs(bot.c0 - top.c0) <= Int(2 * s), abs(bot.c1 - top.c1) <= Int(2 * s) else { continue }
                let x0 = CGFloat(min(top.c0, bot.c0)) / s, x1 = CGFloat(max(top.c1, bot.c1)) / s
                let y0 = CGFloat(top.r0) / s, y1 = CGFloat(bot.r1) / s
                let side: CGFloat = 1.4
                let left = inkFraction(g, CGRect(x: x0 - 0.3, y: y0, width: side, height: y1 - y0))
                let right = inkFraction(g, CGRect(x: x1 - side + 0.3, y: y0, width: side, height: y1 - y0))
                guard left > 0.45, right > 0.45, y1 - y0 >= 6 else { continue }
                // One box, one entry: drop a candidate that mostly overlaps one already kept.
                if out.contains(where: { o in
                    let ix = min(o.x1, x1) - max(o.x0, x0), iy = min(o.y1, y1) - max(o.y0, y0)
                    return ix > 0 && iy > 0 && ix * iy > 0.5 * min((o.x1 - o.x0) * (o.y1 - o.y0), (x1 - x0) * (y1 - y0))
                }) { continue }
                let inner = inkFraction(g, CGRect(x: x0 + (x1 - x0) * 0.22, y: y0 + (y1 - y0) * 0.22,
                                                  width: (x1 - x0) * 0.56, height: (y1 - y0) * 0.56))
                let it = Item(.checkbox, "", x0, x1, y0, y1)
                it.checked = inner > 0.12
                out.append(it)
                break
            }
        }
        return out
    }

    static func inkFraction(_ g: GrayImage, _ r: CGRect) -> Double {
        let s = g.scale
        let c0 = max(0, Int(r.minX * s)), c1 = min(g.w, Int(r.maxX * s))
        let r0 = max(0, Int(r.minY * s)), r1 = min(g.h, Int(r.maxY * s))
        guard c1 > c0, r1 > r0 else { return 0 }
        var dark = 0
        for y in r0..<r1 { for x in c0..<c1 where g.px[y * g.w + x] < 150 { dark += 1 } }
        return Double(dark) / Double((c1 - c0) * (r1 - r0))
    }

    static func inkFractionExcludingRules(_ g: GrayImage, _ r: CGRect, ruleYs: [CGFloat]) -> Double {
        let s = g.scale
        let c0 = max(0, Int(r.minX * s)), c1 = min(g.w, Int(r.maxX * s))
        let r0 = max(0, Int(r.minY * s)), r1 = min(g.h, Int(r.maxY * s))
        guard c1 > c0, r1 > r0 else { return 0 }
        var dark = 0, total = 0
        for y in r0..<r1 {
            let yp = CGFloat(y) / s
            if ruleYs.contains(where: { abs($0 - yp) < 2 }) { continue }
            for x in c0..<c1 { total += 1; if g.px[y * g.w + x] < 150 { dark += 1 } }
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }

    /// Mean horizontal stroke width inside the word's x-height band, divided by the word height.
    static func strokeRatio(_ g: GrayImage, _ w: Item) -> CGFloat {
        let s = g.scale
        let c0 = max(0, Int(w.x0 * s)), c1 = min(g.w, Int(w.x1 * s))
        let r0 = max(0, Int((w.y0 + w.h * 0.25) * s)), r1 = min(g.h, Int((w.y1 - w.h * 0.3) * s))
        guard c1 > c0 + 2, r1 > r0 else { return 0 }
        var runs = 0, dark = 0
        for y in r0..<r1 {
            var inRun = false
            for x in c0..<c1 {
                if g.px[y * g.w + x] < 150 { dark += 1; if !inRun { runs += 1; inRun = true } } else { inRun = false }
            }
        }
        guard runs > 0 else { return 0 }
        return CGFloat(dark) / CGFloat(runs) / s / max(1, w.h)
    }

    static func overlap(_ a: Item, _ b: Item) -> CGFloat {
        let ix = min(a.x1, b.x1) - max(a.x0, b.x0), iy = min(a.y1, b.y1) - max(a.y0, b.y0)
        guard ix > 0, iy > 0 else { return 0 }
        return (ix * iy) / max(1, (a.x1 - a.x0) * a.h)
    }

    // MARK: - 4. Rows and paragraphs

    final class Row {
        var items: [Item]
        init(_ items: [Item]) { self.items = items }
        var words: [Item] { items.filter { $0.kind == .word } }
        var x0: CGFloat { items.map { $0.x0 }.min() ?? 0 }
        var x1: CGFloat { items.map { $0.x1 }.max() ?? 0 }
        var y0: CGFloat { (items.filter { $0.kind != .blank }.map { $0.y0 }.min()) ?? (items.map { $0.y0 }.min() ?? 0) }
        var y1: CGFloat { items.map { $0.y1 }.max() ?? 0 }
        var cy: CGFloat { (y0 + y1) / 2 }
        var h: CGFloat {
            let hs = words.map { $0.h }.sorted()
            return hs.isEmpty ? max(8, y1 - y0) : hs[hs.count / 2]
        }
        var segments = 1
        var centered = false
    }

    static func buildRows(_ p: PageData, hf: HeaderFooter, keepLetterhead: Bool, report: inout Report) -> [Row] {
        var items: [Item] = []
        let hb = keepLetterhead ? (hf.headerBottom[p.index] ?? 0) : 0
        for (li, l) in p.lines.enumerated() {
            if hf.footerLineIDs.contains("\(p.index):\(li)") { continue }
            if keepLetterhead && hb > 0 && l.y1 <= hb && hf.headerKeys.contains(headerKey(l.text)) { continue }
            if keepLetterhead && hb > 0 && l.y1 <= hb { continue }   // anything else inside the letterhead block
            items.append(contentsOf: l.items)
        }
        items.append(contentsOf: p.extras.filter { $0.y0 >= hb })
        report.checkboxes += p.extras.filter { $0.kind == .checkbox }.count
        report.checkedBoxes += p.extras.filter { $0.kind == .checkbox && $0.checked }.count

        // Handwriting is left out; a signature gets a placeholder that says so.
        report.leftOutMarks += p.dropped.count
        for d in p.dropped where d.y0 >= hb {
            let below = p.lines.contains { l in
                l.y0 > d.y0 && l.y0 - d.y1 < 40 && l.text.lowercased().contains("signat")
            }
            if below {
                let note = Item(.note, "Signed on executed original", d.x0, max(d.x1, d.x0 + 120), d.y0, d.y1)
                items.append(note)
                report.signaturePlaceholders += 1
            }
        }

        if let g = p.gray {
            let labels = items.filter { $0.kind == .word && $0.text.lowercased().hasPrefix("signat") }
            for lab in labels {
                // The label's row starts at the first word left of it on the same line.
                let rowWords = items.filter { $0.kind == .word && abs($0.cy - lab.cy) < lab.h * 0.6 && $0.x1 <= lab.x1 }
                let rx0 = rowWords.map { $0.x0 }.min() ?? lab.x0
                // A scrawl Vision read as a stray word ("n", "~") is part of the signature, not a
                // line of text above it: it must not cap the search, and it is not copied.
                let isScrawl: (Item) -> Bool = { w in
                    w.kind == .word && w.y0 > lab.y0 - 48 && w.y1 < lab.y0 - 1 && w.x1 > rx0 - 10 && w.x0 < rx0 + 240
                        && (w.text.count <= 2 || looksGarbled(w.text))
                }
                let above = items.filter { $0.kind == .word && $0.y1 < lab.y0 - 1 && $0.x1 > rx0 - 10 && $0.x0 < rx0 + 240 && !isScrawl($0) }
                let top = max((above.map { $0.y1 }.max() ?? lab.y0 - 48) + 1, lab.y0 - 48)
                let region = CGRect(x: rx0 - 8, y: top, width: 250, height: max(0, lab.y0 - 2 - top))
                guard region.height > 8 else { continue }
                let ruleYs = p.rules.map { $0.y }
                if inkFractionExcludingRules(g, region, ruleYs: ruleYs) > 0.012 {
                    items.removeAll { isScrawl($0) && $0.y0 >= top - 1 }
                    let note = Item(.note, "Signed on executed original", rx0, rx0 + 150, lab.y0 - 14, lab.y0 - 3)
                    items.append(note)
                    report.signaturePlaceholders += 1
                    report.leftOutMarks += 1
                }
            }
        }

        items.sort { $0.cy < $1.cy }
        var rows: [Row] = []
        for it in items {
            if let r = rows.last {
                let tol = max(r.h, it.kind == .word ? it.h : r.h) * 0.55
                let inBand = it.cy > r.y0 && it.cy < r.y1
                if abs(r.cy - it.cy) < tol || inBand || (it.kind == .blank && it.y1 > r.y0 && it.y1 < r.y1 + r.h * 0.6) {
                    r.items.append(it); continue
                }
            }
            rows.append(Row([it]))
        }
        for r in rows { r.items.sort { $0.x0 < $1.x0 } }
        return rows
    }

    struct Geometry {
        var left: CGFloat, right: CGFloat, top: CGFloat
        var bodyH: CGFloat, baseSize: CGFloat, font: String
    }

    static func geometry(_ pages: [PageData], _ rows: [[Row]]) -> Geometry {
        var lefts: [CGFloat] = [], rights: [CGFloat] = [], tops: [CGFloat] = [], hs: [CGFloat] = []
        var full: [(CGFloat, CGFloat)] = []   // (left, right) of pages that are mostly running text
        for pr in rows {
            let textRows = pr.filter { !$0.words.isEmpty }
            guard !textRows.isEmpty else { continue }
            let xs = textRows.map { $0.x0 }.sorted(), xe = textRows.map { $0.x1 }.sorted()
            lefts.append(xs[xs.count / 25]); rights.append(xe[(xe.count * 9) / 10])
            if textRows.count >= 15 { full.append((xs[xs.count / 25], xe[(xe.count * 9) / 10])) }
            tops.append(textRows[0].y0)
            for r in textRows { for w in r.words where w.text.count >= 3 { hs.append(w.h) } }
        }
        func med(_ a: [CGFloat], _ d: CGFloat) -> CGFloat { a.isEmpty ? d : a.sorted()[a.count / 2] }
        let bodyH = med(hs, 13)
        // Vision / PDF word boxes run about 1.12× the type size for mixed-case text.
        let raw = bodyH / 1.12
        let size = max(8, min(14, (raw * 2).rounded(.down) / 2))
        // The text column comes from the pages that are mostly running text (exhibit pages with a
        // few short lines would narrow it and make Word wrap more than the PDF did).
        let ls = full.isEmpty ? lefts : full.map { $0.0 }
        let ws = full.isEmpty ? zip(lefts, rights).map { $1 - $0 } : full.map { $0.1 - $0.0 }
        let left = max(36, min(110, med(ls, 72) - 2))
        return Geometry(left: left, right: left + med(ws, 468) + 10, top: med(tops, 72) - 4, bodyH: bodyH, baseSize: size, font: "Times New Roman")
    }

    static let markerRx = try! NSRegularExpression(pattern: "^(\\(?([0-9]{1,2}|[A-Za-z]|[ivxIVX]{1,4})[.)])$")

    static func refusal(_ rowsByPage: [[Row]], _ pages: [PageData]) -> String? {
        var tablePages = 0, columnPages = 0, considered = 0
        for (pi, rows) in rowsByPage.enumerated() {
            let textRows = rows.filter { $0.words.count >= 1 }
            guard textRows.count >= 8 else { continue }
            considered += 1
            let W = pages[pi].width
            var tabular = 0, split = 0
            for r in textRows {
                let segs = wordSegments(r)
                if segs.count >= 3 { tabular += 1 }
                if segs.count == 2, let a = segs.first, let b = segs.last,
                   a.1 < W * 0.5, b.0 > W * 0.5, a.1 - a.0 > W * 0.22, b.1 - b.0 > W * 0.22 { split += 1 }
            }
            if ProcessInfo.processInfo.environment["JACK_WORD_DEBUG_BOXES"] != nil {
                print("refusal p\(pi + 1): rows \(textRows.count) tabular \(tabular) split \(split)")
                for r in textRows.prefix(5) { print("   row y \(Int(r.y0))-\(Int(r.y1)): " + r.words.map { "\($0.text)@\(Int($0.x0))-\(Int($0.x1))" }.joined(separator: " ")) }
            }
            if Double(tabular) / Double(textRows.count) > 0.45 { tablePages += 1 }
            if Double(split) / Double(textRows.count) > 0.5 { columnPages += 1 }
        }
        guard considered > 0 else { return nil }
        if Double(tablePages) / Double(considered) >= 0.5 {
            return "Most of this PDF is laid out as a table. In Word it would come out as loose lines that no longer line up, so Jack won’t make it. Copy Text gives you every word in reading order."
        }
        if Double(columnPages) / Double(considered) >= 0.5 {
            return "This PDF is set in columns. Word would run the columns into each other, so Jack won’t make it. Copy Text gives you every word in reading order."
        }
        return nil
    }

    /// Runs of WORDS separated by gaps wider than ~3 spaces (rules, boxes and blanks ignored).
    static func wordSegments(_ r: Row) -> [(CGFloat, CGFloat)] {
        var segs: [(CGFloat, CGFloat)] = []
        let gapMax = max(10, r.h * 1.2)
        for it in r.words {
            if var last = segs.last, it.x0 - last.1 < gapMax { last.1 = max(last.1, it.x1); segs[segs.count - 1] = last }
            else { segs.append((it.x0, it.x1)) }
        }
        return segs
    }

    /// Runs of items separated by gaps wider than ~3 spaces.
    static func segmentsOf(_ r: Row) -> [(CGFloat, CGFloat)] {
        var segs: [(CGFloat, CGFloat)] = []
        let gapMax = max(10, r.h * 1.2)
        let skipMarker = isMarker(r)
        for (k, it) in r.items.enumerated() {
            if k == 0 && skipMarker { continue }
            let prev = k > 0 ? r.items[k - 1] : nil
            let bridged = prev.map { $0.kind == .blank || it.kind == .blank || ($0.underline && it.underline) } ?? false
            if var last = segs.last, it.x0 - last.1 < gapMax || bridged {
                last.1 = max(last.1, it.x1); segs[segs.count - 1] = last
            } else { segs.append((it.x0, it.x1)) }
        }
        return segs
    }

    static func paragraphs(_ rowsByPage: [[Row]], pages: [PageData], geo: Geometry, topY: CGFloat,
                           options: Options, report: inout Report, written: inout [String]) -> [DocxParagraph] {
        var out: [DocxParagraph] = []
        let maxBefore: CGFloat = options.matchPages ? pages[0].height * 0.6 : 30

        for (pi, rows) in rowsByPage.enumerated() {
            guard !rows.isEmpty else {
                if options.matchPages { var p = DocxParagraph(); p.pageBreakBefore = pi > 0; out.append(p) }
                continue
            }
            // Scans sit a little differently on every page: indents are measured from THIS page's
            // own text edge, then laid on the document's margin.
            let textRows = rows.filter { !$0.words.isEmpty }
            let xs = textRows.map { $0.x0 }.sorted(), xe = textRows.map { $0.x1 }.sorted()
            let L = xs.isEmpty ? geo.left : xs[xs.count / 25]
            let R = xe.isEmpty ? geo.right : xe[(xe.count * 9) / 10] + 6
            let W = max(100, R - L)
            let lineH = max(6, median(rows.map { $0.h }))
            // Typical baseline-to-baseline pitch on this page → the "normal" gap between rows.
            var pitches: [CGFloat] = []
            for k in 1..<max(1, rows.count) {
                let d = rows[k].y0 - rows[k - 1].y0
                if d > 0 && d < lineH * 2.2 { pitches.append(d) }
            }
            let normalGap = max(0, median(pitches) - lineH)

            var above: Row? = nil
            for r in rows {
                r.segments = segmentsOf(r).count
                let mid = (r.x0 + r.x1) / 2
                // Centered = clear, roughly equal white space on BOTH sides (an indented full line is not).
                let lg = r.x0 - L, rg = R - r.x1
                r.centered = r.segments == 1 && abs(mid - (L + R) / 2) < W * 0.06 && abs(lg - rg) < W * 0.08
                    && lg > W * 0.12 && rg > W * 0.1 && (r.x1 - r.x0) < W * 0.75
                // ...unless it is the wrapped end of the full line above it, starting where that
                // line's text starts (an indented list item's last line looks centered on its own).
                if r.centered, let a = above, !a.centered, !a.words.isEmpty, a.x1 > R - W * 0.13 {
                    let ax = isMarker(a) && a.items.count > 1 ? a.items[1].x0 : a.x0
                    if abs(r.x0 - ax) < lineH * 0.5 { r.centered = false }
                }
                above = r
            }

            var groups: [[Row]] = []
            var markers: [Bool] = []
            for (k, r) in rows.enumerated() {
                let marker = isMarker(r)
                if k > 0, var g = groups.last {
                    let P = rows[k - 1]
                    let gap = r.y0 - P.y1
                    // The line above is full, or it broke early only because this row's first word
                    // would not have fitted after it (word wrap, not a paragraph end).
                    let firstW = r.words.first.map { $0.x1 - $0.x0 } ?? 0
                    let pFull = P.x1 > R - W * 0.13 || (firstW > 0 && R - P.x1 < firstW + lineH * 0.3)
                    let firstX = g[0].x0
                    let textX = markers[markers.count - 1] && g[0].items.count > 1 ? g[0].items[1].x0 : firstX
                    let cont = !marker && !r.centered && !P.centered && r.segments == 1 && P.segments <= 1
                        && pFull && gap < normalGap + lineH * 0.55
                        && r.x0 > L - 6 && r.x0 < textX + lineH * 0.9
                        && !r.items.contains(where: { $0.kind == .checkbox })
                    if let dp = ProcessInfo.processInfo.environment["JACK_WORD_DEBUG_PAGE"], Int(dp) == pi + 1 {
                        let t = r.words.prefix(4).map { $0.text }.joined(separator: " ")
                        report.debug.append(String(format: "row '%@' x0 %.0f x1 %.0f | L %.0f R %.0f textX %.0f | gap %.1f norm %.1f lineH %.1f | pFull %d seg %d/%d cent %d/%d marker %d → %@",
                            t, r.x0, r.x1, L, R, textX, gap, normalGap, lineH, pFull ? 1 : 0, r.segments, P.segments, r.centered ? 1 : 0, P.centered ? 1 : 0, marker ? 1 : 0, cont ? "join" : "NEW"))
                    }
                    if cont { g.append(r); groups[groups.count - 1] = g; continue }
                }
                groups.append([r]); markers.append(marker)
            }

            var prevBottom: CGFloat? = nil
            for (gi, g) in groups.enumerated() {
                var para = DocxParagraph()
                let first = g[0]
                let gap = prevBottom.map { first.y0 - $0 } ?? (first.y0 - topY)
                para.spaceBefore = max(0, min(gi == 0 ? maxBefore : 24, gap - normalGap))
                if para.spaceBefore < 2 { para.spaceBefore = 0 }
                if gi == 0 { para.pageBreakBefore = options.matchPages && pi > 0 }
                prevBottom = g.last!.y1

                if first.centered && g.count == 1 {
                    para.align = .center
                } else if markers[gi] && first.items.count > 1 {
                    let mx = first.items[0].x0, tx = first.items[1].x0
                    para.leftIndent = max(0, tx - L)
                    para.firstLine = -(tx - mx)
                    if para.leftIndent + para.firstLine < 0 { para.firstLine = -para.leftIndent }
                    para.tabStops.append(para.leftIndent)
                } else if g.count >= 2 {
                    let cont = median(g.dropFirst().map { $0.x0 })
                    para.leftIndent = max(0, cont - L)
                    let fl = first.x0 - cont
                    para.firstLine = abs(fl) < 4 ? 0 : max(-para.leftIndent, fl)
                } else {
                    para.leftIndent = max(0, first.x0 - L)
                }
                if para.leftIndent < 3 { para.leftIndent = 0 }

                // Size: only whole paragraphs set clearly larger or smaller than the body.
                let ph = median(g.flatMap { $0.words }.filter { $0.text.count >= 3 }.map { $0.h })
                var paraSize: CGFloat? = nil
                if ph > 0 {
                    let ratio = ph / geo.bodyH
                    if ratio > 1.3 || (ratio < 0.66 && g.flatMap({ $0.words }).count >= 4) { paraSize = max(6, min(36, (geo.baseSize * ratio * 2).rounded() / 2)) }
                }

                // Runs.
                var runs: [DocxRun] = []
                var lastWasWord: Item? = nil
                for (ri, r) in g.enumerated() {
                    for (k, it) in r.items.enumerated() {
                        var sep: DocxRun? = nil
                        if k == 0 && ri > 0 {
                            if let lw = lastWasWord, lw.text.hasSuffix("-") { sep = nil } else { sep = .text(" ", DocxRunStyle()) }
                        } else if k > 0 {
                            let prev = r.items[k - 1]
                            let gapX = it.x0 - prev.x1
                            if k == 1 && markers[gi] && ri == 0 && para.tabStops.count == 1 {
                                sep = .tab(DocxRunStyle())
                            } else if gapX > max(10, r.h * 1.2) {
                                sep = .tab(DocxRunStyle())
                                para.tabStops.append(max(0, it.x0 - L))
                            } else if prev.kind == .word || it.kind == .word || prev.kind == .checkbox {
                                var st = DocxRunStyle()
                                st.underline = prev.underline && it.underline
                                st.bold = prev.bold && it.bold
                                sep = .text(" ", st)
                            }
                        }
                        if let s = sep { runs.append(s) }
                        switch it.kind {
                        case .word:
                            var st = DocxRunStyle()
                            st.bold = it.bold
                            st.underline = it.underline
                            st.highlight = it.uncertain && options.markUncertain
                            if let ps = paraSize { st.size = ps }
                            runs.append(.text(it.text, st))
                            written.append(contentsOf: tokens(it.text))
                            report.words += 1
                            if it.uncertain { report.uncertainWords += 1 } else { report.agreedWords += 1 }
                            lastWasWord = it
                        case .checkbox:
                            runs.append(.checkbox(it.checked))
                        case .blank:
                            var st = DocxRunStyle(); st.size = geo.baseSize
                            runs.append(.blank(it.x1 - it.x0, st))
                        case .note:
                            var st = DocxRunStyle(); st.italic = true; st.size = max(7, geo.baseSize - 2); st.color = "595959"
                            runs.append(.text(it.text, st))
                            written.append(contentsOf: tokens(it.text))
                        }
                    }
                }
                para.runs = coalesce(runs)
                para.tabStops = Array(Set(para.tabStops.map { ($0 * 2).rounded() / 2 })).sorted()
                if markers[gi] || g.count == 1 && first.words.count <= 8 && first.words.allSatisfy({ $0.bold || $0.underline }) {
                    para.keepWithNext = !markers[gi]
                }
                out.append(para)
            }
        }
        return out
    }

    static func isMarker(_ r: Row) -> Bool {
        guard r.items.count >= 2, let f = r.items.first, f.kind == .word else { return false }
        let t = f.text as NSString
        guard markerRx.firstMatch(in: f.text, range: NSRange(location: 0, length: t.length)) != nil else { return false }
        return r.items[1].x0 - f.x1 > max(4, r.h * 0.45)
    }

    static func coalesce(_ runs: [DocxRun]) -> [DocxRun] {
        var out: [DocxRun] = []
        for r in runs {
            if case .text(let t, let s) = r, let last = out.last, case .text(let lt, let ls) = last,
               s.bold == ls.bold, s.italic == ls.italic, s.underline == ls.underline, s.highlight == ls.highlight,
               s.size == ls.size, s.font == ls.font, s.color == ls.color {
                out[out.count - 1] = .text(lt + t, ls)
            } else {
                out.append(r)
            }
        }
        return out
    }

    // MARK: - 5. Verification helpers

    static func readBack(_ url: URL) -> [String]? {
        func load() -> [String]? {
            guard let a = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                                  documentAttributes: nil) else { return nil }
            return tokens(a.string)
        }
        if Thread.isMainThread { return load() }
        var r: [String]? = nil
        DispatchQueue.main.sync { r = load() }
        return r
    }

    /// Fraction of `a` found in `b` in the same order (greedy, windowed — a sanity check, not a diff).
    static func inOrderRatio(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty else { return 1 }
        var j = 0, hit = 0
        for t in a {
            var k = j
            let limit = min(b.count, j + 60)
            while k < limit && b[k] != t { k += 1 }
            if k < limit { hit += 1; j = k + 1 }
        }
        return Double(hit) / Double(a.count)
    }

    /// Indices of `a` that belong to a longest common subsequence with `b`.
    static func lcsMatches(_ a: [String], _ b: [String]) -> Set<Int> {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var dp = [[UInt16]](repeating: [UInt16](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] &+ 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out = Set<Int>()
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { out.insert(i); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        return out
    }

    /// A letterhead line's identity across pages: its words of 3+ letters/digits. Separators and
    /// stray marks ("|" read as "1" on one page and "•l" on the next) must not make the same
    /// printed line look different from page to page.
    static func headerKey(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { norm(String($0)) }.filter { $0.count >= 3 }.joined(separator: " ")
    }

    static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { Character($0) })
            .replacingOccurrences(of: "[0-9]", with: "#", options: .regularExpression)
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Characters a printed document never uses inside a word: the signature of a misread.
    static func looksGarbled(_ w: String) -> Bool {
        if w.contains("\u{FFFD}") { return true }
        let inner = w.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'’“”()[]"))
        guard inner.count >= 2 else { return false }
        let odd = CharacterSet(charactersIn: "[]{}|\\~^`<>")
        if inner.unicodeScalars.contains(where: { odd.contains($0) }) { return true }
        let letters = inner.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = inner.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        // "c]:lildren", "Fnmili" — letters broken by stray punctuation in the middle.
        if letters >= 3, inner.dropFirst().dropLast().contains(where: { ":;".contains($0) }) { return true }
        if letters >= 2 && digits >= 1 && letters + digits == inner.count && digits < 3 && !inner.hasPrefix("$") {
            // Mixed like "l0ss" — but allow codes like "W9", "2CFR", "90640"-style handled above.
            return inner.count <= 6 ? false : true
        }
        return false
    }

    static func median(_ a: [CGFloat]) -> CGFloat { a.isEmpty ? 0 : a.sorted()[a.count / 2] }

    // MARK: - Self-test

    /// JACK_WORD_SELFTEST=<out.docx> JACK_WORD_SELFTEST_PDF=<in.pdf> [JACK_WORD_SELFTEST_FLOW=1]
    /// Converts headlessly, prints the report to stdout and /tmp/jack-word-selftest.log, exits 0/1.
    static func runSelfTestIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["JACK_WORD_SELFTEST"], let src = env["JACK_WORD_SELFTEST_PDF"] else { return }
        var log = "Jack Save as Word self-test \(Date())\nsource: \(src)\n"
        var ok = false
        if let doc = PDFDocument(url: URL(fileURLWithPath: src)) {
            var opt = Options()
            if env["JACK_WORD_SELFTEST_FLOW"] != nil { opt.matchPages = false }
            let t0 = Date()
            do {
                let r = try export(doc, to: URL(fileURLWithPath: out),
                                   title: URL(fileURLWithPath: src).deletingPathExtension().lastPathComponent, options: opt)
                log += "OK in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s → \(out)\n\(r.summary)\n"
                log += r.debug.joined(separator: "\n") + "\n"
                ok = true
            } catch {
                log += "FAILED: \(error.localizedDescription)\n"
            }
        } else {
            log += "FAILED: cannot open PDF\n"
        }
        print(log)
        try? log.write(toFile: "/tmp/jack-word-selftest.log", atomically: true, encoding: .utf8)
        exit(ok ? 0 : 1)
    }
}

// MARK: - Debug dump (JACK_WORD_DUMP=<dir>)

/// What the engine read, page by page, so another engine (the Windows port) can replay exactly
/// the same inputs without OCR: page size, scan test, text layer, the gray image before and after
/// deskew, both Vision readings (in Vision's own order, plus the order the engine sorted them
/// into) and the letterhead crop. Debug only: nothing here feeds back into the conversion.
/// Numbers are written with Swift's shortest round-trip description, so they parse back exactly.
enum WordDump {
    static let dir: String? = {
        guard let d = ProcessInfo.processInfo.environment["JACK_WORD_DUMP"], !d.isEmpty else { return nil }
        return d
    }()
    static var lastRecognized = "null"

    static func begin(pageCount: Int) {
        guard let d = dir else { return }
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        try? "{\"pageCount\":\(pageCount),\"renderScale\":\(WordExportEngine.renderScale)}\n"
            .write(toFile: d + "/meta.json", atomically: true, encoding: .utf8)
    }

    final class Page {
        let index: Int
        var json: [String] = []
        var skew: CGFloat? = nil
        var deskewed: WordExportEngine.GrayImage? = nil
        var first = "null", second = "null"
        init(index: Int, page: PDFPage, box: CGRect, rendered: WordExportEngine.GrayImage) {
            self.index = index
            json.append("\"index\":\(index)")
            json.append("\"width\":\(box.width),\"height\":\(box.height)")
            json.append("\"pageString\":" + str(page.string ?? ""))
            json.append("\"isScanPage\":\(WordExportEngine.isScanPage(page))")
            json.append("\"render\":" + WordDump.gray(rendered, name: "p\(index + 1)-render.png"))
        }
        func write() {
            guard let d = dir else { return }
            var parts = json
            parts.append("\"skew\":" + (skew.map { "\($0)" } ?? "null"))
            parts.append("\"deskewed\":" + (deskewed.map { WordDump.gray($0, name: "p\(index + 1)-deskew.png") } ?? "null"))
            parts.append("\"first\":" + first)
            parts.append("\"second\":" + second)
            try? ("{" + parts.joined(separator: ",\n") + "}\n").write(toFile: d + "/p\(index + 1).json", atomically: true, encoding: .utf8)
        }
    }

    static func str(_ s: String) -> String {
        var o = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            default:
                if u.value < 0x20 { o += String(format: "\\u%04x", u.value) } else { o.unicodeScalars.append(u) }
            }
        }
        return o + "\""
    }

    static func fnv(_ p: UnsafeRawBufferPointer) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in p { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    static func savePNG(_ cg: CGImage, _ name: String) {
        guard let d = dir, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: d + "/" + name) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    static func gray(_ g: WordExportEngine.GrayImage, name: String) -> String {
        savePNG(g.cg, name)
        let h = g.px.withUnsafeBytes { fnv($0) }
        return "{\"file\":\(str(name)),\"w\":\(g.w),\"h\":\(g.h),\"scale\":\(g.scale),\"fnv\":\"\(h)\"}"
    }

    static func recognized(_ unsorted: [WordExportEngine.Line], sorted: [WordExportEngine.Line]) -> String {
        let lines = unsorted.map { l -> String in
            let items = l.items.map { "{\"text\":\(str($0.text)),\"x0\":\($0.x0),\"x1\":\($0.x1),\"y0\":\($0.y0),\"y1\":\($0.y1)}" }
            return "{\"text\":\(str(l.text)),\"x0\":\(l.x0),\"x1\":\(l.x1),\"y0\":\(l.y0),\"y1\":\(l.y1),\"confidence\":\(l.confidence),\"items\":[" + items.joined(separator: ",") + "]}"
        }
        // Where each sorted line came from, so the port can check its sort reproduces Swift's.
        let order = sorted.map { s in unsorted.firstIndex { $0.items.first === s.items.first && $0.text == s.text && $0.x0 == s.x0 && $0.y0 == s.y0 } ?? -1 }
        return "{\"lines\":[\n" + lines.joined(separator: ",\n") + "],\n\"sortedOrder\":[" + order.map { "\($0)" }.joined(separator: ",") + "]}"
    }

    private static var letterheadJSON: [String] = []

    static func letterheadRaw(_ cg: CGImage, rep: NSBitmapImageRep, page: Int, rect: CGRect, w: Int, h: Int) {
        savePNG(cg, "letterhead-raw.png")
        var hash = ""
        if let p = rep.bitmapData, rep.bitsPerPixel == 32 { hash = fnv(UnsafeRawBufferPointer(start: p, count: rep.pixelsWide * rep.pixelsHigh * 4)) }
        letterheadJSON = ["\"page\":\(page)", "\"x\":\(rect.origin.x),\"y\":\(rect.origin.y),\"width\":\(rect.size.width),\"height\":\(rect.size.height)",
                          "\"w\":\(w),\"h\":\(h),\"bitsPerPixel\":\(rep.bitsPerPixel),\"bytesPerRow\":\(rep.bytesPerRow)",
                          "\"raw\":\"letterhead-raw.png\",\"rawFnv\":\"\(hash)\""]
    }

    static func letterheadFinal(_ png: Data, rep: NSBitmapImageRep) {
        guard let d = dir else { return }
        try? png.write(to: URL(fileURLWithPath: d + "/letterhead.png"))
        var hash = ""
        if let p = rep.bitmapData, rep.bitsPerPixel == 32 { hash = fnv(UnsafeRawBufferPointer(start: p, count: rep.pixelsWide * rep.pixelsHigh * 4)) }
        let parts = letterheadJSON + ["\"png\":\"letterhead.png\",\"liftedFnv\":\"\(hash)\""]
        try? ("{" + parts.joined(separator: ",\n") + "}\n").write(toFile: d + "/letterhead.json", atomically: true, encoding: .utf8)
    }
}
