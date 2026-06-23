// A canvas that captures freehand ink (mouse / trackpad / finger) and exports it
// as a transparent, tightly-cropped signature image.
import AppKit

final class SignatureCaptureView: NSView {
    private var strokes: [[NSPoint]] = []
    private var current: [NSPoint] = []
    private let lineWidth: CGFloat = 2.5

    override var isFlipped: Bool { false }
    var isEmpty: Bool { strokes.isEmpty }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        // baseline guide
        NSColor.separatorColor.setStroke()
        let guide = NSBezierPath()
        guide.move(to: NSPoint(x: 24, y: 28))
        guide.line(to: NSPoint(x: bounds.width - 24, y: 28))
        guide.lineWidth = 1
        guide.stroke()

        NSColor.black.setStroke()
        strokePath(strokes + [current], offset: .zero).stroke()
    }

    private func strokePath(_ all: [[NSPoint]], offset: NSPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for s in all where s.count > 1 {
            path.move(to: NSPoint(x: s[0].x - offset.x, y: s[0].y - offset.y))
            for p in s.dropFirst() { path.line(to: NSPoint(x: p.x - offset.x, y: p.y - offset.y)) }
        }
        return path
    }

    override func mouseDown(with e: NSEvent) { current = [convert(e.locationInWindow, from: nil)]; needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { current.append(convert(e.locationInWindow, from: nil)); needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        if current.count > 1 { strokes.append(current) }
        current = []
        needsDisplay = true
    }

    func clear() { strokes = []; current = []; needsDisplay = true }

    // Crop tightly to the ink and render on a transparent background.
    func signatureImage() -> NSImage? {
        let pts = strokes.flatMap { $0 }
        guard !pts.isEmpty else { return nil }
        let pad: CGFloat = 10
        var minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let origin = NSPoint(x: minX - pad, y: minY - pad)
        let size = NSSize(width: max(1, (maxX - minX) + 2 * pad), height: max(1, (maxY - minY) + 2 * pad))

        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.black.setStroke()
        strokePath(strokes, offset: origin).stroke()
        img.unlockFocus()
        return img
    }
}
