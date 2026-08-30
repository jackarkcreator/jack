// The inline typewriter editor — a floating, rounded, self-sizing text capsule.
//
// Design intent (Keno: "not an 1980s box"): borderless rounded card with a soft shadow and an
// accent hairline, forced LIGHT appearance because it sits on paper (the system dark theme is
// what made the first version render as a black slab on a white page). It grows as you type.
// The padding ring around the text is a deliberate grab area: drag it to reposition while the
// editor is still active — click inside to edit, grab the edge to move.
import AppKit

final class TypewriterEditor: NSView {
    let field = NSTextField()
    var onMoved: (() -> Void)?
    private let pad: CGFloat = 7
    private var dragOffset: NSPoint?

    init(text: String, fontSize: CGFloat, at origin: NSPoint) {
        super.init(frame: .zero)
        wantsLayer = true
        // Paper is light; force the editor light so it reads as ink-on-paper, not a dark slab.
        appearance = NSAppearance(named: .aqua)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = .black
        field.stringValue = text
        field.placeholderString = "Type here…"
        addSubview(field)
        sizeToText(minWidth: 90)
        setFrameOrigin(origin)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Grow the capsule to fit the current text (called as the user types).
    func sizeToText(minWidth: CGFloat = 90) {
        let font = field.font ?? .systemFont(ofSize: 14)
        let text = field.stringValue.isEmpty ? (field.placeholderString ?? " ") : field.stringValue
        let w = max(minWidth, (text as NSString).size(withAttributes: [.font: font]).width + 14)
        let h = font.pointSize + 9
        let keepTopLeft = NSPoint(x: frame.minX, y: frame.maxY)
        setFrameSize(NSSize(width: w + pad * 2, height: h + pad * 2))
        field.frame = bounds.insetBy(dx: pad, dy: pad)
        setFrameOrigin(NSPoint(x: keepTopLeft.x, y: keepTopLeft.y - frame.height))
    }

    /// Where the committed text's top-left should land, in this view's superview coordinates.
    var textTopLeftInSuperview: NSPoint {
        NSPoint(x: frame.minX + pad, y: frame.maxY - pad)
    }

    // The ring outside the text field is the move handle.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard !field.frame.contains(p) else { super.mouseDown(with: event); return }
        dragOffset = NSPoint(x: p.x, y: p.y)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let off = dragOffset, let sv = superview else { super.mouseDragged(with: event); return }
        let p = sv.convert(event.locationInWindow, from: nil)
        setFrameOrigin(NSPoint(x: p.x - off.x, y: p.y - off.y))
    }
    override func mouseUp(with event: NSEvent) {
        if dragOffset != nil { dragOffset = nil; onMoved?() } else { super.mouseUp(with: event) }
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(field.frame, cursor: .iBeam)
    }
}
