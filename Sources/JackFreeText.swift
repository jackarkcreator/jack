// Crisp typed text (Typewriter, Retype, form captions, and FreeText from other apps).
//
// 🧨 On macOS 26 PDFView paints page CONTENT in resolution-matched tiles, but paints every
// ANNOTATION into a separate layer at 1x and scales it up — typed text looked pixelated with
// a grey halo at any zoom while the page text next to it stayed sharp. Ground-truthed with a
// live window capture: native FreeText, a custom-draw subclass, and text drawn inside
// PDFPage.draw side by side — only the page-draw path was crisp.
//
// So on a JackPage, FreeText is drawn by the PAGE, and PDFView's annotation-layer copy is
// suppressed. Who calls draw(with:in:) — stack-traced, macOS 26:
//   - PDFView tiles → JackPage.draw; super.draw does NOT draw annotations there, so JackPage
//     draws whatever super skipped (see JackPage.draw).
//   - PDFPageLayerAnnotationEffect (the blurry 1x layer): a CA backing-store context, type 11.
//   - The FILE WRITER building /AP (addAppearanceForKey, context type 6) and PDFKit's
//     background updateAppearanceStream (type 1, PDF) — both OUTSIDE any page draw.
//   - Flattens/rasterizing engines/print: inside page.draw → super.draw.
// 🧨 Suppression is keyed to the CA context type, NOT "outside a page draw": that first design
// wrote EMPTY appearance streams (`q Q`) into saved files — poppler regenerates FreeText so it
// looked fine; Preview/Acrobat would have shown blank text. Always check the raw /AP bytes.
// Fail-safe: if the type lookup is unavailable or Apple renumbers, nothing is suppressed —
// text draws natively everywhere (blurry on screen, like before; never blank in a file).
//
// Off a JackPage (pages merged in from other documents, persisted copies) this class is
// plain FreeText — the file format is unchanged either way.
import AppKit
import PDFKit

final class JackFreeText: PDFAnnotation {
    /// While the user drags the text, the tiles can't follow it live — let PDFView's layer
    /// show it (as before this fix) and have the page skip it. Cleared at mouse-up, which
    /// then forces a repaint.
    var liveDrag = false

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        if page is JackPage, !liveDrag, !PageDrawScope.isActive,
           CGContextKind.isLayerBackingStore(context) { return }
        PageDrawScope.noteDrawn(self)
        super.draw(with: box, in: context)
    }
}

/// CoreGraphics' context-type query (exported, not in the public headers). Only the CA
/// backing-store type the annotation layer draws into (11, probe-verified on macOS 26) is
/// treated as the layer — anything else, including a missing symbol, draws natively.
enum CGContextKind {
    private typealias GetType = @convention(c) (CGContext) -> Int32
    private static let getType: GetType? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGContextGetType") else { return nil }
        return unsafeBitCast(sym, to: GetType.self)
    }()
    static let layerBackingStore: Int32 = 11

    static func isLayerBackingStore(_ ctx: CGContext) -> Bool {
        guard let getType else { return false }
        return getType(ctx) == layerBackingStore
    }
}

/// Thread-local bookkeeping for "we are inside a JackPage draw" (view tiles render off-main).
enum PageDrawScope {
    private static let depthKey = "jack.pageDrawDepth"
    private static let drawnKey = "jack.pageDrawDrawn"

    static var isActive: Bool { (Thread.current.threadDictionary[depthKey] as? Int ?? 0) > 0 }

    /// Runs `body` inside the scope and returns which JackFreeText annotations drew during it.
    static func run(_ body: () -> Void) -> Set<ObjectIdentifier> {
        let td = Thread.current.threadDictionary
        let depth = td[depthKey] as? Int ?? 0
        let outer = td[drawnKey] as? Set<ObjectIdentifier>
        td[depthKey] = depth + 1
        td[drawnKey] = Set<ObjectIdentifier>()
        body()
        let drawn = td[drawnKey] as? Set<ObjectIdentifier> ?? []
        td[depthKey] = depth
        if depth == 0 { td.removeObject(forKey: drawnKey) } else { td[drawnKey] = (outer ?? []).union(drawn) }
        return drawn
    }

    static func noteDrawn(_ a: PDFAnnotation) {
        guard isActive else { return }
        let td = Thread.current.threadDictionary
        var s = td[drawnKey] as? Set<ObjectIdentifier> ?? []
        s.insert(ObjectIdentifier(a))
        td[drawnKey] = s
    }
}

extension PDFPage {
    /// Sidebar thumbnail through the page-draw path. `thumbnail(of:for:)` bypasses
    /// JackPage.draw, so it would miss page-drawn content (typed text, form chrome).
    func jackThumbnail(fitting size: NSSize, box: PDFDisplayBox = .mediaBox) -> NSImage {
        var b = bounds(for: box).size
        if rotation % 180 != 0 { b = NSSize(width: b.height, height: b.width) }
        guard b.width > 0, b.height > 0 else { return thumbnail(of: size, for: box) }
        let s = min(size.width / b.width, size.height / b.height)
        let out = NSSize(width: max(1, (b.width * s).rounded()), height: max(1, (b.height * s).rounded()))
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let ctx = CGContext(data: nil, width: Int(out.width * scale), height: Int(out.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return thumbnail(of: size, for: box)
        }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: out.width * scale, height: out.height * scale))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: s * scale, y: s * scale)
        draw(with: box, to: ctx)   // applies the box origin + rotation itself
        guard let cg = ctx.makeImage() else { return thumbnail(of: size, for: box) }
        return NSImage(cgImage: cg, size: out)
    }
}
