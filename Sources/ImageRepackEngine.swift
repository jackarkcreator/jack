// Image repack: the compression that text pages need. CompressEngine only re-renders pages
// with NO text layer — but a browser-printed plan set has text on every page and its bloat in
// the embedded images (a 49MB Safari print: two 10800×7200 grayscale sheets stored as 8-bit
// RGB, plain Flate, 37MB between them). This pass rewrites those image streams IN PLACE, at
// full resolution, and leaves every other object byte-for-byte as it was:
//
//   • RGB whose three channels are identical → DeviceGray (lossless, ⅓ the samples)
//   • document-like gray (≥90% of pixels near black/white — scanned or printed sheets) →
//     16 gray levels at 4 bits (max error 8/255: invisible on text and line work; photos and
//     gradients never qualify, so they can't band)
//   • everything else → the same pixels, re-deflated behind a PNG predictor (lossless)
//
// Then the file is rewritten object by object (the old image bytes are gone, not shadowed by
// an incremental update). Scope: classic-xref, unencrypted files — what macOS/Safari/Preview
// write. Anything else returns nil and the caller falls back. The caller must still run
// verify() before the bytes go anywhere.
import AppKit
import Compression
import PDFKit

enum ImageRepackEngine {

    struct Result {
        let data: Data
        let imagesRepacked: Int
    }

    /// Why the last repack() returned nil — for the diag log and the self-test.
    static var lastBailReason = ""

    /// Streams smaller than this aren't worth a decode.
    static let minStreamBytes = 300_000
    /// A gray image is "document-like" when this share of pixels is near black or near white.
    static let documentLikeShare = 0.90

    static func repack(_ source: Data) -> Result? {
        lastBailReason = ""
        let b = [UInt8](source)
        guard let file = PDFFile(b) else { return nil }
        var replaced: [Int: [UInt8]] = [:]
        for num in file.objectNumbers {
            guard let obj = file.object(num), obj.streamRange != nil,
                  obj.streamRange!.count >= minStreamBytes,
                  let rebuilt = repackImage(obj, file) else { continue }
            replaced[num] = rebuilt
        }
        guard !replaced.isEmpty else { lastBailReason = "no image worth repacking"; return nil }
        guard let out = file.rewrite(replacing: replaced) else { return nil }
        return Result(data: Data(out), imagesRepacked: replaced.count)
    }

    /// The proof obligation: reopens, same pages, identical text on every page, and every page
    /// renders like the original. Empty array == verified.
    static func verify(candidate: Data, original: Data) -> [String] {
        guard let a = PDFDocument(data: original) else { return ["original unreadable"] }
        guard let c = PDFDocument(data: candidate) else { return ["output does not reopen"] }
        guard a.pageCount == c.pageCount else { return ["page count \(c.pageCount) != \(a.pageCount)"] }
        var issues: [String] = []
        for i in 0..<a.pageCount {
            guard let pa = a.page(at: i), let pc = c.page(at: i) else { issues.append("page \(i + 1) missing"); continue }
            if (pa.string ?? "") != (pc.string ?? "") { issues.append("page \(i + 1): text changed") }
            guard let ra = render(pa), let rc = render(pc), ra.count == rc.count else {
                issues.append("page \(i + 1): failed to render"); continue
            }
            var sum = 0, far = 0
            for k in 0..<ra.count {
                let d = abs(Int(ra[k]) - Int(rc[k]))
                sum += d
                if d > 48 { far += 1 }
            }
            let mean = Double(sum) / Double(ra.count)
            if mean > 2.0 || Double(far) / Double(ra.count) > 0.001 {
                issues.append(String(format: "page %d: renders differently (mean %.2f, far %d)", i + 1, mean, far))
            }
        }
        return issues
    }

    private static func render(_ page: PDFPage) -> [UInt8]? {
        let box = page.bounds(for: .mediaBox)
        let scale = 800 / max(box.width, box.height, 1)
        let w = max(1, Int(box.width * scale)), h = max(1, Int(box.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: ctx)
        guard let p = ctx.data else { return nil }
        return [UInt8](UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
    }

    // MARK: - One image

    private static func repackImage(_ obj: PDFFile.Object, _ file: PDFFile) -> [UInt8]? {
        let d = obj.dict
        guard d.name("/Subtype") == "/Image",
              d.name("/Filter") == "/FlateDecode" || d.raw("/Filter")?.replacingOccurrences(of: " ", with: "") == "[/FlateDecode]",
              d.raw("/DecodeParms") == nil || d.raw("/DecodeParms") == "null",
              d.raw("/Decode") == nil,
              d.raw("/ImageMask") == nil || d.raw("/ImageMask") == "false",
              !(d.raw("/Mask")?.hasPrefix("[") ?? false),        // color-key mask is in the old color space
              Int(d.raw("/BitsPerComponent") ?? "") == 8,
              let w = Int(d.raw("/Width") ?? ""), let h = Int(d.raw("/Height") ?? ""), w > 0, h > 0,
              let comps = components(of: d.raw("/ColorSpace"), file) else { return nil }

        let range = obj.streamRange!
        guard let pixels = inflate(Array(file.bytes[range]), expected: w * h * comps) else { return nil }

        var gray: [UInt8]? = nil
        if comps == 1 {
            gray = pixels
        } else if comps == 3 {
            var g = [UInt8](repeating: 0, count: w * h)
            var isGray = true
            pixels.withUnsafeBufferPointer { p in
                for i in 0..<(w * h) {
                    let r = p[3 * i]
                    if r != p[3 * i + 1] || r != p[3 * i + 2] { isGray = false; break }
                    g[i] = r
                }
            }
            if isGray { gray = g }
        }

        var bits = 8, colors = comps, rowBytes = w * comps, packed: [UInt8]
        var colorSpace: String? = nil      // nil = keep the original /ColorSpace
        if let g = gray {
            colorSpace = "/DeviceGray"
            colors = 1
            var extreme = 0
            for v in g where v >= 230 || v <= 25 { extreme += 1 }
            if Double(extreme) / Double(g.count) >= documentLikeShare {
                bits = 4
                rowBytes = (w + 1) / 2
                packed = [UInt8](repeating: 0, count: rowBytes * h)
                g.withUnsafeBufferPointer { gp in
                    packed.withUnsafeMutableBufferPointer { pp in
                        for y in 0..<h {
                            for x in 0..<w {
                                let level = min(15, (Int(gp[y * w + x]) + 8) / 17)
                                pp[y * rowBytes + x / 2] |= UInt8(x % 2 == 0 ? level << 4 : level)
                            }
                        }
                    }
                }
            } else {
                rowBytes = w
                packed = g
            }
        } else {
            packed = pixels
        }

        let filtered = pngFilter(packed, rowBytes: rowBytes, height: h, bpp: max(1, colors * bits / 8))
        guard let z = deflate(filtered) else { return nil }
        guard z.count < range.count * 9 / 10 else { return nil }   // not worth a rewrite

        var entries = d.entries.filter { !["/Filter", "/DecodeParms", "/Length", "/BitsPerComponent"].contains($0.key) }
        if let cs = colorSpace {
            entries = entries.filter { $0.key != "/ColorSpace" }
            entries.append((key: "/ColorSpace", raw: cs))
        }
        entries.append((key: "/BitsPerComponent", raw: "\(bits)"))
        entries.append((key: "/Filter", raw: "/FlateDecode"))
        entries.append((key: "/DecodeParms", raw: "<< /Predictor 15 /Colors \(colors) /BitsPerComponent \(bits) /Columns \(w) >>"))
        entries.append((key: "/Length", raw: "\(z.count)"))
        var head = "\(obj.number) \(obj.generation) obj\n<< "
        for e in entries { head += "\(e.key) \(e.raw) " }
        head += ">>\nstream\n"
        var out = PDFFile.bytes(head)
        out += z
        out += Array("\nendstream\nendobj\n".utf8)
        return out
    }

    /// Samples per pixel for the color spaces this pass understands; nil = leave the image alone.
    private static func components(of raw: String?, _ file: PDFFile) -> Int? {
        guard var cs = raw?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let ref = PDFFile.ref(cs), let body = file.object(ref)?.bodyText { cs = body }
        switch cs {
        case "/DeviceRGB": return 3
        case "/DeviceGray": return 1
        default:
            let inner = cs.trimmingCharacters(in: CharacterSet(charactersIn: "[] \n\r\t"))
            let parts = inner.split(whereSeparator: { " \n\r\t".contains($0) })
            guard parts.count == 4, parts[0] == "/ICCBased",
                  let n = Int(parts[1]), let icc = file.object(n),
                  let comps = Int(icc.dict.raw("/N") ?? ""), comps == 1 || comps == 3 else { return nil }
            return comps
        }
    }

    // MARK: - PNG predictor (per-row filter choice: minimum sum of absolute residuals)

    private static func pngFilter(_ data: [UInt8], rowBytes: Int, height: Int, bpp: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (rowBytes + 1) * height)
        var cand = [[UInt8]](repeating: [UInt8](repeating: 0, count: rowBytes), count: 5)
        let zero = [UInt8](repeating: 0, count: rowBytes)
        data.withUnsafeBufferPointer { src in
            for y in 0..<height {
                let row = y * rowBytes, prevRow = (y - 1) * rowBytes
                var best = 0, bestScore = Int.max
                for f in 0..<5 {
                    var score = 0
                    cand[f].withUnsafeMutableBufferPointer { c in
                        zero.withUnsafeBufferPointer { z in
                            for x in 0..<rowBytes {
                                let cur = src[row + x]
                                let a = x >= bpp ? src[row + x - bpp] : 0
                                let b = y > 0 ? src[prevRow + x] : z[x]
                                let cc = (x >= bpp && y > 0) ? src[prevRow + x - bpp] : 0
                                let v: UInt8
                                switch f {
                                case 0: v = cur
                                case 1: v = cur &- a
                                case 2: v = cur &- b
                                case 3: v = cur &- UInt8((Int(a) + Int(b)) / 2)
                                default:
                                    let p = Int(a) + Int(b) - Int(cc)
                                    let pa = abs(p - Int(a)), pb = abs(p - Int(b)), pc = abs(p - Int(cc))
                                    v = cur &- ((pa <= pb && pa <= pc) ? a : (pb <= pc ? b : cc))
                                }
                                c[x] = v
                                score += v < 128 ? Int(v) : 256 - Int(v)
                            }
                        }
                    }
                    if score < bestScore { bestScore = score; best = f }
                }
                out[y * (rowBytes + 1)] = UInt8(best)
                out.replaceSubrange((y * (rowBytes + 1) + 1)..<((y + 1) * (rowBytes + 1)), with: cand[best])
            }
        }
        return out
    }

    // MARK: - zlib framing over Compression's raw DEFLATE

    private static func inflate(_ z: [UInt8], expected: Int) -> [UInt8]? {
        guard z.count > 2, z[0] & 0x0F == 8 else { return nil }
        guard let raw = stream(Array(z[2...]), op: COMPRESSION_STREAM_DECODE, limit: expected),
              raw.count >= expected else { return nil }
        return raw.count == expected ? raw : Array(raw[0..<expected])
    }

    private static func deflate(_ data: [UInt8]) -> [UInt8]? {
        guard let raw = stream(data, op: COMPRESSION_STREAM_ENCODE, limit: nil) else { return nil }
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < data.count {                       // adler32, 5552-byte blocks
            let end = min(i + 5552, data.count)
            while i < end { a &+= UInt32(data[i]); b &+= a; i += 1 }
            a %= 65521; b %= 65521
        }
        let adler = (b << 16) | a
        return [0x78, 0x9C] + raw + [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF),
                                     UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)]
    }

    private static func stream(_ input: [UInt8], op: compression_stream_operation, limit: Int?) -> [UInt8]? {
        let chunk = 1 << 20
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var s = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&s, op, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&s) }
        var out: [UInt8] = []
        if let limit { out.reserveCapacity(limit) }
        return input.withUnsafeBufferPointer { src -> [UInt8]? in
            s.src_ptr = src.baseAddress!
            s.src_size = src.count
            while true {
                s.dst_ptr = dst
                s.dst_size = chunk
                let status = compression_stream_process(&s, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(contentsOf: UnsafeBufferPointer(start: dst, count: chunk - s.dst_size))
                if let limit, out.count >= limit { return out }
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return out
                default: return nil
                }
            }
        }
    }
}

// MARK: - Minimal classic-xref PDF reader / rewriter

/// Byte-level view of a classic-xref PDF: the newest offset for every object, each object's
/// exact byte span, its dictionary's top-level entries and its stream data range. Enough to
/// copy objects verbatim and swap a few — nothing here interprets content streams.
struct PDFFile {
    let bytes: [UInt8]
    private var offsets: [Int: Int] = [:]
    private var trailer: PDFDict
    private let header: [UInt8]

    struct Object {
        let number: Int
        let generation: Int
        let span: Range<Int>              // "N G obj" … "endobj"
        let dict: PDFDict
        let streamRange: Range<Int>?
        let bodyText: String              // the value text (non-stream objects; small)
    }

    var objectNumbers: [Int] { offsets.keys.sorted() }

    init?(_ b: [UInt8]) {
        bytes = b
        trailer = PDFDict(entries: [])
        guard b.count > 32, let nl = b[0..<min(64, b.count)].firstIndex(where: { $0 == 0x0A || $0 == 0x0D }),
              String(decoding: b[0..<5], as: UTF8.self) == "%PDF-" else {
            ImageRepackEngine.lastBailReason = "not a PDF header"; return nil
        }
        header = Array(b[0..<nl])
        let tail = String(decoding: b[max(0, b.count - 2048)...], as: UTF8.self)
        guard let r = tail.range(of: "startxref", options: .backwards),
              let start = Int(tail[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                                .split(whereSeparator: { $0.isWhitespace }).first ?? "") else {
            ImageRepackEngine.lastBailReason = "no startxref"; return nil
        }
        var cursor: Int? = start
        var first = true
        var hops = 0
        while let at = cursor, hops < 64 {
            hops += 1
            guard at >= 0, at + 4 < b.count, String(decoding: b[at..<at + 4], as: UTF8.self) == "xref" else {
                ImageRepackEngine.lastBailReason = "xref stream (not a classic table)"; return nil
            }
            var p = at + 4
            while true {
                p = Self.skipWS(b, p)
                if Self.matches(b, p, "trailer") { p += 7; break }
                guard let (startNum, p1) = Self.int(b, p), let (count, p2) = Self.int(b, Self.skipWS(b, p1)) else {
                    ImageRepackEngine.lastBailReason = "bad xref subsection"; return nil
                }
                p = p2
                for k in 0..<count {
                    guard let (off, q1) = Self.int(b, Self.skipWS(b, p)),
                          let (_, q2) = Self.int(b, Self.skipWS(b, q1)) else {
                        ImageRepackEngine.lastBailReason = "bad xref entry"; return nil
                    }
                    let q3 = Self.skipWS(b, q2)
                    guard q3 < b.count else { return nil }
                    if b[q3] == UInt8(ascii: "n"), offsets[startNum + k] == nil, startNum + k > 0 {
                        offsets[startNum + k] = off              // newest section wins
                    }
                    p = q3 + 1
                }
            }
            p = Self.skipWS(b, p)
            guard let end = Self.valueEnd(b, p), let d = PDFDict(b, p, end) else {
                ImageRepackEngine.lastBailReason = "bad trailer"; return nil
            }
            if first { trailer = d; first = false }
            if d.raw("/XRefStm") != nil { ImageRepackEngine.lastBailReason = "hybrid xref"; return nil }
            if d.raw("/Encrypt") != nil { ImageRepackEngine.lastBailReason = "encrypted"; return nil }
            cursor = d.raw("/Prev").flatMap { Int($0) }
        }
        guard trailer.raw("/Root") != nil else { ImageRepackEngine.lastBailReason = "no /Root"; return nil }
    }

    func object(_ num: Int) -> Object? {
        guard let off = offsets[num], off < bytes.count else { return nil }
        let b = bytes
        guard let (n, p1) = Self.int(b, Self.skipWS(b, off)), n == num,
              let (g, p2) = Self.int(b, Self.skipWS(b, p1)) else { return nil }
        var p = Self.skipWS(b, p2)
        guard Self.matches(b, p, "obj") else { return nil }
        p = Self.skipWS(b, p + 3)
        guard let vEnd = Self.valueEnd(b, p) else { return nil }
        let dict = PDFDict(b, p, vEnd) ?? PDFDict(entries: [])
        let bodyText = vEnd - p < 4096 ? PDFFile.latin1(b[p..<vEnd]) : ""
        var q = Self.skipWS(b, vEnd)
        var streamRange: Range<Int>? = nil
        if Self.matches(b, q, "stream") {
            q += 6
            if q < b.count, b[q] == 0x0D { q += 1 }
            if q < b.count, b[q] == 0x0A { q += 1 }
            var length: Int? = nil
            if let raw = dict.raw("/Length") {
                if let ref = Self.ref(raw) { length = object(ref).flatMap { Int($0.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                else { length = Int(raw) }
            }
            guard let len = length, q + len <= b.count else { return nil }
            let e = Self.skipWS(b, q + len)
            guard Self.matches(b, e, "endstream") else { return nil }   // wrong /Length → never guess
            streamRange = q..<(q + len)
            q = Self.skipWS(b, e + 9)
        }
        guard Self.matches(b, q, "endobj") else { return nil }
        return Object(number: n, generation: g, span: off..<(q + 6), dict: dict,
                      streamRange: streamRange, bodyText: bodyText)
    }

    /// Every live object, in number order, verbatim except `replacing`; fresh xref + trailer.
    func rewrite(replacing: [Int: [UInt8]]) -> [UInt8]? {
        var out = header + Self.bytes("\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n")
        var newOffsets: [Int: Int] = [:]
        var generations: [Int: Int] = [:]
        for num in objectNumbers {
            guard let obj = object(num) else {
                ImageRepackEngine.lastBailReason = "object \(num) unreadable"; return nil
            }
            newOffsets[num] = out.count
            generations[num] = obj.generation
            if let r = replacing[num] { out += r } else { out += bytes[obj.span]; out.append(0x0A) }
        }
        let size = (objectNumbers.last ?? 0) + 1
        let xrefAt = out.count
        var x = "xref\n0 \(size)\n0000000000 65535 f \n"
        for n in 1..<max(1, size) {
            if let o = newOffsets[n] { x += String(format: "%010d %05d n \n", o, generations[n] ?? 0) }
            else { x += "0000000000 65535 f \n" }
        }
        var t = "trailer\n<< /Size \(size)"
        for e in trailer.entries where !["/Size", "/Prev", "/XRefStm"].contains(e.key) { t += " \(e.key) \(e.raw)" }
        t += " >>\nstartxref\n\(xrefAt)\n%%EOF\n"
        out += Self.bytes(x + t)
        return out
    }

    // MARK: lexing

    /// Dictionary text round-trips through Latin-1: one byte per character, binary-safe.
    static func latin1(_ s: ArraySlice<UInt8>) -> String { String(bytes: s, encoding: .isoLatin1) ?? "" }
    static func bytes(_ s: String) -> [UInt8] { Array(s.data(using: .isoLatin1) ?? Data(s.utf8)) }

    static func ref(_ s: String) -> Int? {
        let p = s.split(whereSeparator: { $0.isWhitespace })
        guard p.count == 3, p[2] == "R", let n = Int(p[0]), Int(p[1]) != nil else { return nil }
        return n
    }

    static func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00 }
    static func isDelim(_ c: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(c) }

    static func skipWS(_ b: [UInt8], _ i: Int) -> Int {
        var i = i
        while i < b.count {
            if isWS(b[i]) { i += 1 }
            else if b[i] == UInt8(ascii: "%") { while i < b.count, b[i] != 0x0A, b[i] != 0x0D { i += 1 } }
            else { break }
        }
        return i
    }

    static func matches(_ b: [UInt8], _ i: Int, _ word: String) -> Bool {
        let w = Array(word.utf8)
        return i + w.count <= b.count && Array(b[i..<i + w.count]) == w
    }

    static func int(_ b: [UInt8], _ i: Int) -> (Int, Int)? {
        var j = i, v = 0
        while j < b.count, b[j] >= 0x30, b[j] <= 0x39 { v = v * 10 + Int(b[j] - 0x30); j += 1 }
        return j > i ? (v, j) : nil
    }

    private static func tokenEnd(_ b: [UInt8], _ i: Int) -> Int {
        var j = i
        while j < b.count, !isWS(b[j]), !isDelim(b[j]) { j += 1 }
        return j
    }

    /// End index (exclusive) of the PDF value starting at `i`; refs ("12 0 R") count as one value.
    static func valueEnd(_ b: [UInt8], _ i: Int) -> Int? {
        guard i < b.count else { return nil }
        let c = b[i]
        if c == UInt8(ascii: "<"), i + 1 < b.count, b[i + 1] == UInt8(ascii: "<") {
            var p = i + 2
            while true {
                p = skipWS(b, p)
                guard p < b.count else { return nil }
                if matches(b, p, ">>") { return p + 2 }
                guard b[p] == UInt8(ascii: "/") else { return nil }
                p = tokenEnd(b, p + 1)
                guard let e = valueEnd(b, skipWS(b, p)) else { return nil }
                p = e
            }
        }
        if c == UInt8(ascii: "<") {
            guard let e = b[i...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
            return e + 1
        }
        if c == UInt8(ascii: "[") {
            var p = i + 1
            while true {
                p = skipWS(b, p)
                guard p < b.count else { return nil }
                if b[p] == UInt8(ascii: "]") { return p + 1 }
                guard let e = valueEnd(b, p) else { return nil }
                p = e
            }
        }
        if c == UInt8(ascii: "(") {
            var p = i + 1, depth = 1
            while p < b.count {
                if b[p] == UInt8(ascii: "\\") { p += 2; continue }
                if b[p] == UInt8(ascii: "(") { depth += 1 }
                if b[p] == UInt8(ascii: ")") { depth -= 1; if depth == 0 { return p + 1 } }
                p += 1
            }
            return nil
        }
        if c == UInt8(ascii: "/") { return tokenEnd(b, i + 1) }
        let e = tokenEnd(b, i)
        guard e > i else { return nil }
        // "N G R" reads as one value
        if let (_, e1) = int(b, i), e1 == e {
            let s1 = skipWS(b, e)
            if let (_, e2) = int(b, s1) {
                let s2 = skipWS(b, e2)
                if s2 < b.count, b[s2] == UInt8(ascii: "R"), s2 + 1 >= b.count || isWS(b[s2 + 1]) || isDelim(b[s2 + 1]) {
                    return s2 + 1
                }
            }
        }
        return e
    }
}

/// Top-level entries of a dictionary, values kept as their raw source text.
struct PDFDict {
    var entries: [(key: String, raw: String)]

    init(entries: [(key: String, raw: String)]) { self.entries = entries }

    init?(_ b: [UInt8], _ start: Int, _ end: Int) {
        guard PDFFile.matches(b, start, "<<") else { return nil }
        entries = []
        var p = start + 2
        while true {
            p = PDFFile.skipWS(b, p)
            guard p < end else { return nil }
            if PDFFile.matches(b, p, ">>") { return }
            guard b[p] == UInt8(ascii: "/") else { return nil }
            var k = p + 1
            while k < b.count, !PDFFile.isWS(b[k]), !PDFFile.isDelim(b[k]) { k += 1 }
            let key = PDFFile.latin1(b[p..<k])
            let vs = PDFFile.skipWS(b, k)
            guard let ve = PDFFile.valueEnd(b, vs) else { return nil }
            entries.append((key: key, raw: PDFFile.latin1(b[vs..<ve])))
            p = ve
        }
    }

    func raw(_ key: String) -> String? { entries.first(where: { $0.key == key })?.raw }
    func name(_ key: String) -> String? { raw(key).flatMap { $0.hasPrefix("/") ? $0 : nil } }
}
