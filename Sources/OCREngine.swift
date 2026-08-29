// Make Searchable: on-device OCR (Vision) that burns an INVISIBLE text layer under scanned
// pages, so search/select/copy work. Pages that already carry text pass through untouched.
// Nothing leaves the Mac — that's the point.
import AppKit
import PDFKit
import Vision

enum OCREngine {

    static let renderScale: CGFloat = 4.0   // 288 DPI recognition input

    struct Word { let text: String; let box: CGRect }   // box in page coordinates

    /// Write a searchable copy of `doc` to `url`. Returns (ok, ocrPageCount).
    /// `progress` is called on an arbitrary queue with (pageIndex, pageCount).
    static func makeSearchable(_ doc: PDFDocument, to url: URL,
                               progress: ((Int, Int) -> Void)? = nil) -> (Bool, Int) {
        guard let firstPage = doc.page(at: 0) else { return (false, 0) }
        var firstBox = firstPage.bounds(for: .mediaBox)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return (false, 0) }

        var ocrCount = 0
        for i in 0..<doc.pageCount {
            progress?(i, doc.pageCount)
            guard let page = doc.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.saveGState()
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()

            // Only OCR pages with no usable text layer.
            let existing = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.isEmpty, let words = recognize(page: page), !words.isEmpty {
                ocrCount += 1
                drawInvisible(words, into: ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return (true, ocrCount)
    }

    /// Run Vision text recognition on a rendered page; boxes come back in page coordinates.
    static func recognize(page: PDFPage) -> [Word]? {
        let box = page.bounds(for: .mediaBox)
        let w = Int(box.width * renderScale), h = Int(box.height * renderScale)
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
        cg.scaleBy(x: renderScale, y: renderScale)
        cg.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: cg)
        cg.restoreGState()
        guard let image = cg.makeImage() ?? rep.cgImage else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "es-MX"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return nil }

        var words: [Word] = []
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first, !candidate.string.isEmpty else { continue }
            // Vision boxes are normalized with origin bottom-left — same orientation as PDF space.
            let b = obs.boundingBox
            let rect = CGRect(x: box.origin.x + b.origin.x * box.width,
                              y: box.origin.y + b.origin.y * box.height,
                              width: b.width * box.width,
                              height: b.height * box.height)
            words.append(Word(text: candidate.string, box: rect))
        }
        return words
    }

    // Draw each recognized line as invisible text (render mode 3) sized to its box.
    private static func drawInvisible(_ words: [Word], into ctx: CGContext) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for word in words {
            let baseSize: CGFloat = 12
            let font = NSFont.systemFont(ofSize: baseSize)
            let attr = NSAttributedString(string: word.text, attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attr)
            let measured = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            guard measured > 0 else { continue }
            let scale = word.box.width / measured
            let sized = NSFont.systemFont(ofSize: baseSize * scale)
            let sizedLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: word.text, attributes: [.font: sized]))
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: word.box.minX, y: word.box.minY + word.box.height * 0.2)
            CTLineDraw(sizedLine, ctx)
        }
        ctx.restoreGState()
    }
}
