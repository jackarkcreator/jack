// Incremental save: the fix for PDFKit's most destructive habit.
//
// PDFDocument.write(to:) REWRITES every page, converting text to vector outlines for any
// font it cannot re-embed — a branded 2.1MB deliverable became an unsearchable 24MB file with
// zero Jack code involved. The only way to protect untouched pages is to never rewrite them:
// keep the ORIGINAL file bytes and append an incremental update section that supersedes only
// the pages Jack actually changed.
//
// Scope (v2.7.1): pages swapped by Jack's own raster tools (erase, redact, retype, compress,
// OCR) — pages Jack built, whose exact structure Jack controls. Anything else (annotations
// added to untouched vector pages, form authoring, structural reorders, xref-stream files)
// returns nil and the caller falls back to the full rewrite — worst case is today's behavior.
//
// SAFETY GATE: the caller must verify the produced bytes (reopen, compare untouched-page text
// to the original, render the swapped pages) before writing them anywhere. Build never throws
// styled output it cannot prove; verification failure = fallback, never a broken file.
import AppKit
import PDFKit

enum IncrementalSave {

    /// Why the last build() returned nil — diagnostic breadcrumb for the save gate.
    static var lastBailReason = ""

    struct Baseline {
        let data: Data
        let pageIDs: [ObjectIdentifier]
        let annotationIDs: [Set<ObjectIdentifier>]
        // A standard crop or rotation mutates the SAME page object — identity alone would
        // classify it "untouched" and the incremental save would silently drop the change.
        let cropBoxes: [CGRect]
        let rotations: [Int]
    }

    static func baseline(for doc: PDFDocument, data: Data) -> Baseline {
        var ids: [ObjectIdentifier] = []
        var anns: [Set<ObjectIdentifier>] = []
        var crops: [CGRect] = []
        var rots: [Int] = []
        for i in 0..<doc.pageCount {
            let p = doc.page(at: i)!
            ids.append(ObjectIdentifier(p))
            anns.append(Set(p.annotations.map(ObjectIdentifier.init)))
            crops.append(p.bounds(for: .cropBox))
            rots.append(p.rotation)
        }
        return Baseline(data: data, pageIDs: ids, annotationIDs: anns, cropBoxes: crops, rotations: rots)
    }

    /// nil = not eligible / could not build — caller falls back to the full rewrite.
    static func build(current: PDFDocument, baseline: Baseline) -> Data? {
        // ---- eligibility: only raster-swapped pages differ ----
        guard current.pageCount == baseline.pageIDs.count else { lastBailReason = "pageCount \(current.pageCount) != baseline \(baseline.pageIDs.count)"; return nil }
        var swapped: [Int] = []
        for i in 0..<current.pageCount {
            guard let page = current.page(at: i) else { lastBailReason = "page \(i) nil"; return nil }
            if ObjectIdentifier(page) == baseline.pageIDs[i] {
                // untouched pages must be truly untouched — an added highlight or typewriter
                // note needs the v2.8 annotation emitter, not silence. Same for a crop or
                // rotation on the original page object.
                guard Set(page.annotations.map(ObjectIdentifier.init)) == baseline.annotationIDs[i] else {
                    lastBailReason = "page \(i + 1): annotations changed on an untouched page (\(page.annotations.count) now, kinds: \(Set(page.annotations.map { $0.type ?? "?" })))"
                    return nil
                }
                guard page.bounds(for: .cropBox) == baseline.cropBoxes[i] else { lastBailReason = "page \(i + 1): cropBox changed"; return nil }
                guard page.rotation == baseline.rotations[i] else { lastBailReason = "page \(i + 1): rotation changed"; return nil }
            } else {
                // swapped page: must be one of ours — rasterized (no text layer), carrying
                // at most FreeText annotations (retype).
                guard (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    lastBailReason = "page \(i + 1): swapped page still has text"; return nil
                }
                guard page.annotations.allSatisfy({ $0.type == "FreeText" }) else {
                    lastBailReason = "page \(i + 1): swapped page carries non-FreeText annotations: \(Set(page.annotations.map { $0.type ?? "?" }))"
                    return nil
                }
                swapped.append(i)
            }
        }
        guard !swapped.isEmpty else { return baseline.data }   // nothing changed → original bytes

        // ---- parse the original: classic xref only ----
        guard let parsed = Parsed(data: baseline.data) else { lastBailReason = "parser rejected baseline bytes"; return nil }
        guard parsed.pageObjectNumbers.count == baseline.pageIDs.count else { lastBailReason = "tree walk found \(parsed.pageObjectNumbers.count) pages, want \(baseline.pageIDs.count)"; return nil }

        var out = baseline.data
        if out.last != 0x0A { out.append(0x0A) }
        var nextObj = parsed.size
        var newEntries: [(num: Int, offset: Int)] = []
        func emit(_ num: Int, _ body: [UInt8]) {
            newEntries.append((num, out.count))
            out.append(Data("\(num) 0 obj\n".utf8))
            out.append(Data(body))
            out.append(Data("\nendobj\n".utf8))
        }
        func emitStr(_ num: Int, _ body: String) { emit(num, Array(body.utf8)) }

        for i in swapped {
            guard let page = current.page(at: i) else { return nil }
            let pageNum = parsed.pageObjectNumbers[i]
            guard let parentRef = parsed.pageParentRef(objectNumber: pageNum) else { return nil }
            let box = page.bounds(for: .mediaBox)

            // Image: reuse the raster's own JPEG bytes when the page exposes them (no extra
            // compression generation); otherwise render once at the engine's DPI.
            var jpeg: Data?
            var pxW = 0, pxH = 0
            if let img = ImageHitEngine.images(on: page).first, let d = img.jpegData {
                jpeg = d; pxW = img.pixelWidth; pxH = img.pixelHeight
            }
            if jpeg == nil {
                guard let (d, w, h) = Self.renderJPEG(page: page, box: box) else { return nil }
                jpeg = d; pxW = w; pxH = h
            }
            guard let jpegData = jpeg, pxW > 0, pxH > 0 else { return nil }

            let imgNum = nextObj; nextObj += 1
            var imgObj = Array("<< /Type /XObject /Subtype /Image /Width \(pxW) /Height \(pxH) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length \(jpegData.count) >>\nstream\n".utf8)
            imgObj.append(contentsOf: [UInt8](jpegData))
            imgObj.append(contentsOf: Array("\nendstream".utf8))
            emit(imgNum, imgObj)

            let contentNum = nextObj; nextObj += 1
            let cs = String(format: "q %.2f 0 0 %.2f %.2f %.2f cm /ImJ0 Do Q",
                            box.width, box.height, box.minX, box.minY)
            emitStr(contentNum, "<< /Length \(cs.utf8.count) >>\nstream\n\(cs)\nendstream")

            // FreeText annotations (retype). /DA uses Helvetica — metrically compatible with
            // the Arial family retype resolves; viewers regenerate the appearance from it.
            var annotRefs: [String] = []
            for a in page.annotations where a.type == "FreeText" {
                let n = nextObj; nextObj += 1
                let r = a.bounds
                let size = a.font?.pointSize ?? 12
                let c = (a.fontColor ?? .black).usingColorSpace(.deviceRGB) ?? .black
                let contents = (a.contents ?? "")
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "(", with: "\\(")
                    .replacingOccurrences(of: ")", with: "\\)")
                emitStr(n, String(format: "<< /Type /Annot /Subtype /FreeText /Rect [%.2f %.2f %.2f %.2f] /Contents (%@) /DA (/Helv %.1f Tf %.3f %.3f %.3f rg) /Border [0 0 0] /F 4 >>",
                                  r.minX, r.minY, r.maxX, r.maxY, contents as NSString, size,
                                  c.redComponent, c.greenComponent, c.blueComponent))
                annotRefs.append("\(n) 0 R")
            }
            let annots = annotRefs.isEmpty ? "" : " /Annots [ \(annotRefs.joined(separator: " ")) ]"

            emitStr(pageNum, String(format: "<< /Type /Page /Parent %@ /MediaBox [%.2f %.2f %.2f %.2f] /Resources << /XObject << /ImJ0 %d 0 R >> /ProcSet [ /PDF /ImageC ] >> /Contents %d 0 R%@ >>",
                                    parentRef, box.minX, box.minY, box.maxX, box.maxY,
                                    imgNum, contentNum, annots))
        }

        // Refresh /Info so the Jack marker survives (this is what lets a later ⌘S go straight
        // to the file instead of offering a copy again).
        var infoClause = ""
        do {
            let n = nextObj; nextObj += 1
            var body = "<< /Creator (Jack \\(ThinkOpen\\))"
            if let title = parsed.infoTitle { body += " /Title (\(title))" }
            body += " >>"
            emitStr(n, body)
            infoClause = " /Info \(n) 0 R"
        }

        // ---- classic xref append ----
        let xrefOffset = out.count
        var xref = "xref\n"
        for e in newEntries.sorted(by: { $0.num < $1.num }) {
            xref += "\(e.num) 1\n" + String(format: "%010d 00000 n \n", e.offset)
        }
        var trailer = "trailer\n<< /Size \(nextObj) /Root \(parsed.rootRef) /Prev \(parsed.startxref)\(infoClause)"
        if let id = parsed.idClause { trailer += " /ID \(id)" }
        trailer += " >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out.append(Data((xref + trailer).utf8))
        return out
    }

    /// The caller's proof obligation, packaged: reopen and compare. Empty array == verified.
    static func verify(candidate: Data, current: PDFDocument, baseline: Baseline) -> [String] {
        guard let re = PDFDocument(data: candidate) else { return ["output does not reopen"] }
        guard re.pageCount == current.pageCount else { return ["page count \(re.pageCount) != \(current.pageCount)"] }
        guard let orig = PDFDocument(data: baseline.data) else { return ["baseline unreadable"] }
        var issues: [String] = []
        for i in 0..<current.pageCount {
            let isSwapped = ObjectIdentifier(current.page(at: i)!) != baseline.pageIDs[i]
            if isSwapped {
                if RedactionEngine.inkLevel(of: re.page(at: i)!) < 0,
                   RedactionEngine.inkLevel(of: current.page(at: i)!) > 200 {
                    issues.append("page \(i + 1): swapped page failed to render")
                }
                let wantNotes = current.page(at: i)!.annotations.filter { $0.type == "FreeText" }.count
                let gotNotes = re.page(at: i)!.annotations.filter { $0.type == "FreeText" }.count
                if wantNotes != gotNotes { issues.append("page \(i + 1): \(gotNotes)/\(wantNotes) annotations") }
            } else {
                // THE point of the whole exercise: untouched pages keep their text, exactly.
                let a = (orig.page(at: i)?.string ?? "")
                let b = (re.page(at: i)?.string ?? "")
                if a != b { issues.append("page \(i + 1): text changed on an untouched page") }
            }
        }
        return issues
    }

    // MARK: - Rendering fallback

    private static func renderJPEG(page: PDFPage, box: CGRect) -> (Data, Int, Int)? {
        let scale = RedactionEngine.rasterScale
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = g.cgContext
        cg.setFillColor(.white); cg.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: cg)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: RedactionEngine.jpegQuality])
        else { return nil }
        return (jpeg, w, h)
    }

    // MARK: - Classic-xref parser (xref streams / object streams → nil → fallback)

    private struct Parsed {
        let startxref: Int
        let size: Int
        let rootRef: String
        let idClause: String?
        let infoTitle: String?
        let pageObjectNumbers: [Int]
        private let text: NSString
        private let offsets: [Int: Int]

        init?(data: Data) {
            guard let s = String(data: data, encoding: .isoLatin1) else { return nil }
            let ns = s as NSString
            self.text = ns

            func lastMatch(_ pattern: String) -> NSTextCheckingResult? {
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
                return re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)).last
            }
            guard let sx = lastMatch(#"startxref\s+(\d+)"#),
                  let start = Int(ns.substring(with: sx.range(at: 1))) else { return nil }
            startxref = start

            // Walk the /Prev chain, collecting classic sections; any non-classic section → nil.
            var offsets: [Int: Int] = [:]
            var trailerBits: [String] = []
            var cursor: Int? = start
            var hops = 0
            while let at = cursor, hops < 64 {
                hops += 1
                guard at >= 0, at < ns.length - 4 else { return nil }
                guard ns.substring(with: NSRange(location: at, length: 4)) == "xref" else { return nil }
                var idx = at + 4
                // subsections: "start count" then count 20-byte entries
                while true {
                    // skip whitespace — by SCALAR VALUE. 🧨 In a Swift string literal, "\r\n"
                    // fuses into ONE grapheme cluster, so " \r\n".contains("\n") is FALSE and
                    // a character-set check silently never matches a bare newline.
                    while idx < ns.length, [0x20, 0x0D, 0x0A, 0x09].contains(Int(ns.character(at: idx))) { idx += 1 }
                    let lineEnd = ns.range(of: "\n", options: [], range: NSRange(location: idx, length: min(64, ns.length - idx)))
                    guard lineEnd.location != NSNotFound else { return nil }
                    let header = ns.substring(with: NSRange(location: idx, length: lineEnd.location - idx))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if header.hasPrefix("trailer") { idx += "trailer".count; break }
                    let parts = header.split(separator: " ")
                    guard parts.count == 2, let first = Int(parts[0]), let count = Int(parts[1]) else {
                        if header.hasPrefix("trailer") { break } else { return nil }
                    }
                    idx = lineEnd.location + 1
                    for k in 0..<count {
                        guard idx + 18 <= ns.length else { return nil }
                        let entry = ns.substring(with: NSRange(location: idx, length: 18))
                        let f = entry.split(separator: " ")
                        if f.count >= 3, f[2].hasPrefix("n"), let off = Int(f[0]) {
                            let num = first + k
                            if offsets[num] == nil { offsets[num] = off }   // newest section wins
                        }
                        idx += 20
                        // tolerate 19-byte lines (\n only): resync on digits
                        while idx < ns.length, !"0123456789t".contains(Character(UnicodeScalar(ns.character(at: idx))!)) { idx += 1 }
                    }
                }
                // trailer dict
                guard let open = ns.range(of: "<<", options: [], range: NSRange(location: idx, length: min(200, ns.length - idx))).toOptional() else { return nil }
                var depth = 0; var j = open.location; var close = -1
                while j < ns.length - 1 {
                    let two = ns.substring(with: NSRange(location: j, length: 2))
                    if two == "<<" { depth += 1; j += 2; continue }
                    if two == ">>" { depth -= 1; if depth == 0 { close = j + 2; break }; j += 2; continue }
                    j += 1
                }
                guard close > 0 else { return nil }
                let trailer = ns.substring(with: NSRange(location: open.location, length: close - open.location))
                trailerBits.append(trailer)
                if let m = trailer.range(of: #"/Prev\s+(\d+)"#, options: .regularExpression) {
                    cursor = Int(trailer[m].replacingOccurrences(of: "/Prev", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
                } else { cursor = nil }
            }
            self.offsets = offsets

            let newest = trailerBits.first ?? ""
            guard let rootM = newest.range(of: #"/Root\s+\d+\s+0\s+R"#, options: .regularExpression) else { return nil }
            rootRef = String(newest[rootM]).replacingOccurrences(of: "/Root", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sizeM = newest.range(of: #"/Size\s+(\d+)"#, options: .regularExpression),
                  let sz = Int(String(newest[sizeM]).replacingOccurrences(of: "/Size", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil }
            size = sz
            idClause = newest.range(of: #"/ID\s*(\[[^\]]*\])"#, options: .regularExpression)
                .map { String(newest[$0]).replacingOccurrences(of: "/ID", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }

            // /Info title (best effort)
            var title: String? = nil
            if let infoM = newest.range(of: #"/Info\s+(\d+)\s+0\s+R"#, options: .regularExpression),
               let n = Int(String(newest[infoM]).components(separatedBy: CharacterSet.decimalDigits.inverted).filter({ !$0.isEmpty }).first ?? ""),
               let body = Self.objectBody(ns, offsets, n),
               let tM = body.range(of: #"/Title\s*\(([^)]*)\)"#, options: .regularExpression) {
                title = String(body[tM]).replacingOccurrences(of: #"/Title\s*\("#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: ")", with: "")
            }
            infoTitle = title

            // page tree walk
            guard let rootNum = Int(rootRef.split(separator: " ").first ?? ""),
                  let catalog = Self.objectBody(ns, offsets, rootNum),
                  let pagesM = catalog.range(of: #"/Pages\s+(\d+)\s+0\s+R"#, options: .regularExpression),
                  let pagesNum = Int(String(catalog[pagesM]).components(separatedBy: CharacterSet.decimalDigits.inverted).filter({ !$0.isEmpty }).first ?? "")
            else { return nil }
            var pages: [Int] = []
            var stack: [Int] = [pagesNum]
            var guardCount = 0
            func collect(_ num: Int) -> Bool {
                guardCount += 1
                if guardCount > 50_000 { return false }
                guard let body = Self.objectBody(ns, offsets, num) else { return false }
                if body.range(of: #"/Type\s*/Pages"#, options: .regularExpression) != nil {
                    guard let kidsM = body.range(of: #"/Kids\s*\[([^\]]*)\]"#, options: .regularExpression) else { return false }
                    let kids = String(body[kidsM])
                    // Refs by regex — a Kids array wraps across lines, and split-by-"R" left
                    // "\n280" for Int() to reject, silently dropping pages from the tree.
                    var nums: [Int] = []
                    if let re = try? NSRegularExpression(pattern: #"(\d+)\s+0\s+R"#) {
                        let nsk = kids as NSString
                        for m in re.matches(in: kids, options: [], range: NSRange(location: 0, length: nsk.length)) {
                            if let v = Int(nsk.substring(with: m.range(at: 1))) { nums.append(v) }
                        }
                    }
                    for k in nums { if !collect(k) { return false } }
                    return true
                } else if body.range(of: #"/Type\s*/Page\b"#, options: .regularExpression) != nil {
                    pages.append(num)
                    return true
                }
                return false
            }
            guard collect(pagesNum) else { return nil }
            _ = stack
            pageObjectNumbers = pages
        }

        func pageParentRef(objectNumber: Int) -> String? {
            guard let body = Self.objectBody(text, offsets, objectNumber),
                  let m = body.range(of: #"/Parent\s+\d+\s+0\s+R"#, options: .regularExpression) else { return nil }
            return String(body[m]).replacingOccurrences(of: "/Parent", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func objectBody(_ ns: NSString, _ offsets: [Int: Int], _ num: Int) -> String? {
            guard let off = offsets[num], off < ns.length else { return nil }
            let searchLen = min(20_000, ns.length - off)
            let range = NSRange(location: off, length: searchLen)
            let end = ns.range(of: "endobj", options: [], range: range)
            guard end.location != NSNotFound else { return nil }
            return ns.substring(with: NSRange(location: off, length: end.location - off))
        }
    }
}

private extension NSRange {
    func toOptional() -> NSRange? { location == NSNotFound ? nil : self }
}
