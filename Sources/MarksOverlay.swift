// 3.2.1: typed text, comment badges and image stamps (PageDrawnAnnotation) draw in a LIVE
// per-page overlay instead of inside PDFView's cached page tiles.
//
// Before: the marks drew inside the tiles (crisp — the annotation layer is 1x and blurry on
// macOS 26), so every add/move/undo had to REASSIGN the whole document behind a snapshot
// cover to flush the tile cache. Measured on a real window: ~0.4 s cover per edit whose pixels
// differed from the live page on 7–8% of the visible area — the "refresh" blink and the
// "pixelated" moment users saw. One Undo reloaded twice.
//
// Now: PDFKit's own page overlay views (macOS 13+) host a view per visible page that draws
// the marks at the view's resolution (crisp at any zoom), and an edit only marks that view
// dirty. The tiles skip these marks — tile renders are recognized by PDFKit's tile queue
// (probe, macOS 26: queue "PDFKit.PDFTilePool.workQueue", context type 8, via
// -[PDFView drawPage:toContext:]). Thumbnails, flatten, print and the file writer don't run on
// that queue, so they keep drawing the marks exactly as before.
// Fallback: macOS 11–12, or JACK_OVERLAY=0, keeps the old tile path + document reassign.
import AppKit
import PDFKit

enum MarksOverlay {
    /// The live overlay is in charge of page-drawn marks (else the tiles draw them, as before).
    static let enabled: Bool = {
        guard ProcessInfo.processInfo.environment["JACK_OVERLAY"] != "0" else { return false }
        if #available(macOS 13.0, *) { return true }
        return false
    }()

    /// True while PDFKit renders a page tile for PDFView (never for thumbnails/flatten/print/save).
    static var isTileRender: Bool {
        String(cString: __dispatch_queue_get_label(nil)).hasPrefix("PDFKit.PDFTilePool")
    }
}

/// One page's marks, drawn live above the page. Never takes the mouse: SigningPDFView keeps
/// handling clicks, drags and selection exactly as before.
final class MarksOverlayView: NSView {
    weak var page: PDFPage?
    var displayBox: PDFDisplayBox = .cropBox

    init(page: PDFPage, displayBox: PDFDisplayBox) {
        self.page = page
        self.displayBox = displayBox
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let page, page is JackPage, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let marks = page.annotations.filter { a in
            guard let pd = a as? PageDrawnAnnotation else { return false }
            return a.shouldDisplay && !pd.liveDrag
        }
        guard !marks.isEmpty else { return }
        // The overlay covers the page as displayed (rotation applied). Map page space into it:
        // PDFPage.transform rotates/translates into a box-sized space at the origin, then scale.
        let box = page.bounds(for: displayBox)
        let quarter = ((page.rotation % 360) + 360) % 360 / 90
        let shown = quarter % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
        guard shown.width > 0, shown.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        ctx.saveGState()
        if isFlipped {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.scaleBy(x: bounds.width / shown.width, y: bounds.height / shown.height)
        page.transform(ctx, for: displayBox)
        // Inside the scope the marks draw for real (outside it they suppress their 1x layer copy).
        _ = PageDrawScope.run { marks.forEach { $0.draw(with: displayBox, in: ctx) } }
        ctx.restoreGState()
    }
}
