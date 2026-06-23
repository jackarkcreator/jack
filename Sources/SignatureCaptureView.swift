// A canvas that captures freehand ink and exports it as a transparent, cropped signature image.
// Two input modes:
//  • Mouse/trackpad click-drag (default)
//  • Trackpad glide — move one finger on the trackpad with no click (like Preview), which flows easier.
import AppKit

final class SignatureCaptureView: NSView {
    private var strokes: [[NSPoint]] = []
    private var current: [NSPoint] = []
    private let lineWidth: CGFloat = 2.5

    private var trackpadMode = false
    private var trackedIdentity: (NSCopying & NSObjectProtocol)?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    var isEmpty: Bool { strokes.isEmpty }

    func setTrackpad(_ on: Bool) {
        trackpadMode = on
        allowedTouchTypes = on ? [.indirect] : []
        if on { window?.makeFirstResponder(self) }
        // Starting a fresh mode shouldn't carry a half-finished stroke.
        current = []
        trackedIdentity = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

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

    // MARK: mouse input (when not in trackpad mode)

    override func mouseDown(with e: NSEvent) {
        guard !trackpadMode else { return }
        current = [convert(e.locationInWindow, from: nil)]; needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        guard !trackpadMode else { return }
        current.append(convert(e.locationInWindow, from: nil)); needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        guard !trackpadMode else { return }
        if current.count > 1 { strokes.append(current) }
        current = []; needsDisplay = true
    }

    // MARK: trackpad glide input (indirect touches — no click needed)

    private func point(for t: NSTouch) -> NSPoint {
        let n = t.normalizedPosition   // origin bottom-left, 0…1
        return NSPoint(x: n.x * bounds.width, y: n.y * bounds.height)
    }

    override func touchesBegan(with event: NSEvent) {
        guard trackpadMode, let t = event.touches(matching: .began, in: self).first else { return }
        trackedIdentity = t.identity
        current = [point(for: t)]
        needsDisplay = true
    }
    override func touchesMoved(with event: NSEvent) {
        guard trackpadMode, let id = trackedIdentity,
              let t = event.touches(matching: .moved, in: self).first(where: { $0.identity.isEqual(id) }) else { return }
        current.append(point(for: t)); needsDisplay = true
    }
    override func touchesEnded(with event: NSEvent) { endTouchStroke() }
    override func touchesCancelled(with event: NSEvent) { endTouchStroke() }

    private func endTouchStroke() {
        guard trackpadMode else { return }
        if current.count > 1 { strokes.append(current) }
        current = []
        trackedIdentity = nil
        needsDisplay = true
    }

    // MARK: export

    func clear() { strokes = []; current = []; needsDisplay = true }

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
