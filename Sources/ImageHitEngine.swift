// "What image is under the cursor?" — PDFKit has no API for this, so we scan the page's
// content stream ourselves: walk q/Q/cm/Do with a CTM stack, and every image XObject's
// drawn rectangle is its CTM applied to the unit square. Form XObjects recurse with their
// /Matrix composed. UI-free and headlessly kill-tested.
//
// Extraction policy: JPEG-embedded images (DCTDecode — every scan and phone photo) are
// passed through byte-for-byte at native quality. Everything else falls back to rendering
// the image's rect at its native pixel density — visually identical, no decode-case zoo.
import AppKit
import PDFKit

struct PDFPageImage {
    let rect: CGRect          // drawn rectangle in PDF user space
    let pixelWidth: Int
    let pixelHeight: Int
    let jpegData: Data?       // DCTDecode passthrough when available
}

enum ImageHitEngine {

    /// All images drawn on the page, in paint order (last = topmost).
    static func images(on page: PDFPage) -> [PDFPageImage] {
        guard let pageRef = page.pageRef else { return [] }
        let scan = Scanner()
        scan.run(page: pageRef)
        return scan.found
    }

    /// Topmost image whose drawn rect contains the point (page space).
    static func image(at point: CGPoint, on page: PDFPage) -> PDFPageImage? {
        images(on: page).last {
            $0.rect.insetBy(dx: -2, dy: -2).contains(point) && $0.rect.width > 8 && $0.rect.height > 8
        }
    }

    /// Best-quality NSImage for extraction: JPEG bytes if present, else a native-DPI
    /// render of the image's rect (annotations and overlays never included).
    static func extract(_ img: PDFPageImage, from page: PDFPage) -> NSImage? {
        if let data = img.jpegData, let ns = NSImage(data: data), ns.size.width > 0 { return ns }
        return renderNative(img, from: page)
    }

    /// PNG or passthrough-JPEG file data + a suggested extension.
    static func fileData(_ img: PDFPageImage, from page: PDFPage) -> (Data, String)? {
        if let data = img.jpegData, NSImage(data: data)?.size.width ?? 0 > 0 { return (data, "jpg") }
        guard let ns = renderNative(img, from: page),
              let tiff = ns.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, "png")
    }

    private static func renderNative(_ img: PDFPageImage, from page: PDFPage) -> NSImage? {
        let scale = max(1, CGFloat(img.pixelWidth) / max(1, img.rect.width))
        let w = Int(img.rect.width * scale), h = Int(img.rect.height * scale)
        guard w > 0, h > 0, w < 20000, h < 20000,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = gctx.cgContext
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        cg.saveGState()
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -img.rect.origin.x, y: -img.rect.origin.y)
        let overlays = page.annotations
        overlays.forEach { page.removeAnnotation($0) }
        page.draw(with: .mediaBox, to: cg)
        overlays.forEach { page.addAnnotation($0) }
        cg.restoreGState()
        guard let out = rep.cgImage else { return nil }
        return NSImage(cgImage: out, size: img.rect.size)
    }

    // MARK: - Content-stream scanner

    private final class Scanner {
        var found: [PDFPageImage] = []
        private var ctm = CGAffineTransform.identity
        private var stack: [CGAffineTransform] = []
        private var resources: [CGPDFDictionaryRef] = []
        private var contentStack: [CGPDFContentStreamRef] = []
        private var depth = 0

        func run(page: CGPDFPage) {
            guard let pageDict = page.dictionary else { return }
            var res: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(pageDict, "Resources", &res)
            if let res { resources.append(res) }
            guard let content = CGPDFContentStreamCreateWithPage(page) as CGPDFContentStreamRef? else { return }
            scanStream(content)
        }

        private func scanStream(_ content: CGPDFContentStreamRef) {
            contentStack.append(content)
            defer { contentStack.removeLast() }
            let table = CGPDFOperatorTableCreate()!
            let info = Unmanaged.passUnretained(self).toOpaque()

            CGPDFOperatorTableSetCallback(table, "q") { scanner, info in
                let me = Unmanaged<Scanner>.fromOpaque(info!).takeUnretainedValue()
                me.stack.append(me.ctm)
            }
            CGPDFOperatorTableSetCallback(table, "Q") { scanner, info in
                let me = Unmanaged<Scanner>.fromOpaque(info!).takeUnretainedValue()
                if !me.stack.isEmpty { me.ctm = me.stack.removeLast() }
            }
            CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
                let me = Unmanaged<Scanner>.fromOpaque(info!).takeUnretainedValue()
                var v = [CGPDFReal](repeating: 0, count: 6)
                for i in (0..<6).reversed() {
                    var r: CGPDFReal = 0
                    if CGPDFScannerPopNumber(scanner, &r) { v[i] = r }
                }
                let m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                me.ctm = m.concatenating(me.ctm)
            }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
                let me = Unmanaged<Scanner>.fromOpaque(info!).takeUnretainedValue()
                var name: UnsafePointer<Int8>?
                guard CGPDFScannerPopName(scanner, &name), let name else { return }
                me.handleXObject(named: name, scanner: scanner)
            }

            let s = CGPDFScannerCreate(content, table, info)
            CGPDFScannerScan(s)
            CGPDFScannerRelease(s)
            CGPDFOperatorTableRelease(table)
        }

        private func handleXObject(named name: UnsafePointer<Int8>, scanner: CGPDFScannerRef) {
            guard let res = resources.last else { return }
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjects), let xobjects else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(xobjects, name, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtypeName: UnsafePointer<Int8>?
            CGPDFDictionaryGetName(dict, "Subtype", &subtypeName)
            let subtype = subtypeName.map { String(cString: $0) } ?? ""

            if subtype == "Image" {
                var wInt: CGPDFInteger = 0, hInt: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(dict, "Width", &wInt)
                CGPDFDictionaryGetInteger(dict, "Height", &hInt)
                // Drawn rect = CTM applied to the unit square.
                let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm)
                var fmt = CGPDFDataFormat.raw
                let data = CGPDFStreamCopyData(stream, &fmt)
                let jpeg = (fmt == .jpegEncoded) ? (data as Data?) : nil
                found.append(PDFPageImage(rect: rect.standardized,
                                          pixelWidth: Int(wInt), pixelHeight: Int(hInt),
                                          jpegData: jpeg))
            } else if subtype == "Form", depth < 8 {
                depth += 1
                defer { depth -= 1 }
                let saved = ctm
                var matrixArr: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "Matrix", &matrixArr), let matrixArr {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<min(6, CGPDFArrayGetCount(matrixArr)) {
                        var r: CGPDFReal = 0
                        if CGPDFArrayGetNumber(matrixArr, i, &r) { v[i] = r }
                    }
                    let m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                    ctm = m.concatenating(ctm)
                }
                var formRes: CGPDFDictionaryRef?
                let pushedRes = CGPDFDictionaryGetDictionary(dict, "Resources", &formRes) && formRes != nil
                if pushedRes { resources.append(formRes!) }
                if let parent = contentStack.last {
                    scanStream(CGPDFContentStreamCreateWithStream(stream, dict, parent))
                }
                if pushedRes { resources.removeLast() }
                ctm = saved
            }
        }
    }
}
