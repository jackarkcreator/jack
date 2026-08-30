// Remove Object: delete ONE image from a page without touching anything else on it.
//
// Erase rasterizes the whole page and paints over a region — it works on anything, but the
// page stops being vector and the paint has to guess a background colour. Removing a discrete
// object is the better answer when there IS a discrete object: the logo goes, the black header
// bar behind it stays exactly as drawn, the text layer survives, and nothing is painted at all.
//
// 🧨 THE TRAP THIS ENGINE EXISTS TO AVOID: dropping the `Do` operator (or the /Resources entry
// that resolves it) makes the image STOP DISPLAYING while its bytes sit in the file, fully
// recoverable. That is cosmetic removal wearing a better disguise, and it is exactly what Jack
// refuses to do. So the image OBJECT ITSELF is superseded by an empty Form XObject through an
// incremental update, and the result is then round-tripped through PDFKit, which writes a
// single flattened revision — the superseded bytes are not carried into it. The result is then
// PROVEN: the output is parsed and the image object carrying those pixels must be absent. If it
// is still there, the page is thrown away and the user is told to use Erase instead.
//
// 🧨 Why the proof is structural and not a byte-search for the pixels: CGPDFStreamCopyData with
// .raw hands back DECODED samples, while the file stores them Flate-compressed — searching the
// output for decoded bytes never matches, so it would pass whether or not the image was removed.
// A negative control caught exactly that. Counting image objects by their /Width + /Height is a
// check that can actually fail.
//
// Superseding rather than unlinking also keeps the file VALID: the name in /Resources still
// resolves, now to a form that draws nothing. No dangling reference for a strict reader to
// choke on.
import AppKit
import PDFKit

enum ObjectRemovalEngine {

    /// A page with `image` removed, or nil if it could not be removed AND PROVEN removed.
    /// Never returns a page whose pixels survive — a nil result means "use Erase instead".
    static func removing(_ image: PDFPageImage, from page: PDFPage) -> PDFPage? {
        // Work on a single-page copy: PDFKit-writer output is the only shape the byte layer
        // is ground-truthed against (classic xref, direct /Length, no object streams).
        let single = PDFDocument()
        guard let copy = page.copy() as? PDFPage else { return nil }
        single.insert(copy, at: 0)
        guard let data = single.dataRepresentation(),
              let reparsed = PDFDocument(data: data),
              let rp = reparsed.page(at: 0) else { return nil }

        // The extraction rewrote the file, so resource names must be re-read from THIS layout.
        // Match by drawn rect: the geometry is what the user pointed at.
        guard let target = ImageHitEngine.images(on: rp).first(where: {
            abs($0.rect.minX - image.rect.minX) < 1 && abs($0.rect.minY - image.rect.minY) < 1 &&
            abs($0.rect.width - image.rect.width) < 1 && abs($0.rect.height - image.rect.height) < 1
        }) else { return nil }

        guard let patched = supersede(name: target.name, in: data),
              let reloaded = PDFDocument(data: patched),
              let flattened = reloaded.dataRepresentation(),
              let out = PDFDocument(data: flattened),
              let outPage = out.page(at: 0) else { return nil }

        // Proof, not assumption. The object carrying these pixels must be gone from the file
        // we are about to hand back — not merely unreferenced, and not merely undisplayed.
        let before = imageObjectCount(in: data, width: target.pixelWidth, height: target.pixelHeight)
        let after = imageObjectCount(in: flattened, width: target.pixelWidth, height: target.pixelHeight)
        guard before > 0, after == before - 1 else { return nil }
        // And it must no longer be drawn on the page.
        guard !ImageHitEngine.images(on: outPage).contains(where: {
            $0.pixelWidth == target.pixelWidth && $0.pixelHeight == target.pixelHeight &&
            abs($0.rect.minX - target.rect.minX) < 1 && abs($0.rect.minY - target.rect.minY) < 1
        }) else { return nil }
        // 🧨 And the REST of the page must still be there. Checking only that the image left
        // would accept a page that came back completely blank — an empty page trivially
        // satisfies "the image is gone".
        guard RedactionEngine.preservesContent(original: page, replacement: outPage,
                                               regions: [image.rect]) else { return nil }
        return outPage
    }

    /// How many image XObjects of exactly these pixel dimensions exist in the file.
    /// Dimensions rather than a payload search: see the note at the top of this file.
    static func imageObjectCount(in data: Data, width: Int, height: Int) -> Int {
        guard let s = String(data: data, encoding: .isoLatin1),
              let re = try? NSRegularExpression(pattern: #"\d+\s+0\s+obj(.*?)endobj"#,
                                                options: [.dotMatchesLineSeparators]) else { return 0 }
        let ns = s as NSString
        var n = 0
        for m in re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: m.range(at: 1))
            guard body.range(of: #"/Subtype\s*/Image"#, options: .regularExpression) != nil,
                  body.range(of: "/Width\\s+\(width)\\b", options: .regularExpression) != nil,
                  body.range(of: "/Height\\s+\(height)\\b", options: .regularExpression) != nil
            else { continue }
            n += 1
        }
        return n
    }

    /// True when the object is safe to remove this way — used to decide whether to offer it.
    static func canRemove(_ image: PDFPageImage) -> Bool { !image.name.isEmpty }

    // MARK: - Byte layer

    /// Append an incremental update that replaces the image object with an empty Form XObject.
    /// Fail-open: any parse anomaly returns nil and the caller leaves the document alone.
    private static func supersede(name: String, in data: Data) -> Data? {
        // Latin-1 keeps a 1:1 byte↔UTF-16-unit mapping, so NSRange offsets are byte offsets.
        guard let s = String(data: data, encoding: .isoLatin1) else { return nil }
        let ns = s as NSString
        let whole = NSRange(location: 0, length: ns.length)

        func matches(_ pattern: String, in range: NSRange? = nil) -> [NSTextCheckingResult] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            else { return [] }
            return re.matches(in: s, options: [], range: range ?? whole)
        }

        // Every object body, so a candidate reference can be checked against its target.
        var bodies: [Int: String] = [:]
        for m in matches(#"(\d+)\s+0\s+obj(.*?)endobj"#) {
            if let n = Int(ns.substring(with: m.range(at: 1))) { bodies[n] = ns.substring(with: m.range(at: 2)) }
        }
        guard !bodies.isEmpty else { return nil }

        // Find "/<name> N 0 R" where N really is an image. The resource dictionary may live in
        // the page object or in its own object (or a Form XObject's) — scanning every body
        // covers all three without special-casing.
        let escaped = NSRegularExpression.escapedPattern(for: name)
        var targets = Set<Int>()
        for m in matches("/\(escaped)\\s+(\\d+)\\s+0\\s+R") {
            guard let n = Int(ns.substring(with: m.range(at: 1))), let body = bodies[n] else { continue }
            if body.range(of: #"/Subtype\s*/Image"#, options: .regularExpression) != nil { targets.insert(n) }
        }
        // Exactly one, or we do not know what we would be destroying.
        guard targets.count == 1, let imageNum = targets.first else { return nil }

        // Trailer of the current revision — the incremental update chains to it via /Prev.
        let trailerLoc = ns.range(of: "trailer", options: .backwards)
        guard trailerLoc.location != NSNotFound else { return nil }
        let tail = NSRange(location: trailerLoc.location, length: ns.length - trailerLoc.location)
        guard let sizeM = matches(#"/Size\s+(\d+)"#, in: tail).first,
              let rootM = matches(#"/Root\s+(\d+)\s+0\s+R"#, in: tail).first,
              let sxM = matches(#"startxref\s+(\d+)"#, in: tail).first,
              let size = Int(ns.substring(with: sizeM.range(at: 1))),
              let rootNum = Int(ns.substring(with: rootM.range(at: 1))),
              let prevXref = Int(ns.substring(with: sxM.range(at: 1))) else { return nil }
        let infoM = matches(#"/Info\s+(\d+)\s+0\s+R"#, in: tail).first
        let idM = matches(#"/ID\s*(\[[^\]]*\])"#, in: tail).first

        var out = data
        if let last = out.last, last != 0x0A { out.append(0x0A) }

        // An empty form draws nothing and is a legal target for the existing `Do`.
        let offset = out.count
        let replacement = "<< /Type /XObject /Subtype /Form /BBox [0 0 0 0] /Resources << >> /Length 0 >>\nstream\nendstream"
        out.append(Data("\(imageNum) 0 obj\n\(replacement)\nendobj\n".utf8))

        let xrefOffset = out.count
        var xref = "xref\n\(imageNum) 1\n"
        xref += String(format: "%010d 00000 n \n", offset)
        var trailer = "trailer\n<< /Size \(size) /Root \(rootNum) 0 R /Prev \(prevXref)"
        if let infoM { trailer += " /Info \(ns.substring(with: infoM.range(at: 1))) 0 R" }
        if let idM { trailer += " /ID \(ns.substring(with: idM.range(at: 1)))" }
        trailer += " >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out.append(Data((xref + trailer).utf8))
        return out
    }

}
