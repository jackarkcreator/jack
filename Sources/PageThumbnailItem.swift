// One page tile (sidebar + Page Organizer): thumbnail + page number. v3: selection is a
// rounded teal plate behind the page and a teal page-number pill (no square accent ring).
import AppKit

/// Draws the selection plate and the number pill; everything else is ordinary subviews.
final class ThumbnailTileView: NSView {
    var isSelected = false { didSet { needsDisplay = true } }
    weak var numberLabel: NSTextField?
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            Chrome.tintSoft.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10).fill()
            if let l = numberLabel {
                let w = ceil(l.attributedStringValue.size().width) + 14
                let pill = NSRect(x: l.frame.midX - w / 2, y: l.frame.midY - 9, width: w, height: 18)
                Chrome.tint.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
            }
        }
    }
}

final class PageThumbnailItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("PageThumbnailItem")

    private let thumb = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let dash = CAShapeLayer()   // the empty-slot outline (taken mode)

    override func loadView() {
        let v = ThumbnailTileView(frame: NSRect(x: 0, y: 0, width: 150, height: 196))
        v.numberLabel = label

        thumb.frame = NSRect(x: 8, y: 26, width: 134, height: 162)
        thumb.imageScaling = .scaleProportionallyDown
        thumb.wantsLayer = true
        thumb.layer?.backgroundColor = NSColor.white.cgColor
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        v.addSubview(thumb)

        label.frame = NSRect(x: 0, y: 6, width: 150, height: 16)
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        v.addSubview(label)

        self.view = v
        self.imageView = thumb
        self.textField = label
    }

    func configure(_ image: NSImage?, label text: String) {
        thumb.image = image
        thumb.layer?.backgroundColor = NSColor.white.cgColor
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        dash.removeFromSuperlayer()
        label.stringValue = text
        updateRing()   // a reused tile keeps the right selection look
    }

    /// The organizer's physical-truth mode: a page moved into the New PDF leaves its slot
    /// EMPTY — a dashed outline where it used to sit, number intact, nothing renumbers.
    func configureTaken(label text: String) {
        thumb.image = nil
        thumb.layer?.backgroundColor = NSColor.clear.cgColor
        thumb.layer?.borderWidth = 0
        dash.frame = thumb.bounds
        dash.path = CGPath(roundedRect: thumb.bounds.insetBy(dx: 1, dy: 1),
                           cornerWidth: 6, cornerHeight: 6, transform: nil)
        dash.fillColor = NSColor.clear.cgColor
        dash.strokeColor = NSColor.tertiaryLabelColor.cgColor
        dash.lineWidth = 1.5
        dash.lineDashPattern = [6, 5]
        if dash.superlayer == nil { thumb.layer?.addSublayer(dash) }
        label.stringValue = text
        label.textColor = .tertiaryLabelColor
    }

    override var isSelected: Bool { didSet { updateRing() } }

    private func updateRing() {
        (view as? ThumbnailTileView)?.isSelected = isSelected
        label.font = isSelected ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 11)
        label.textColor = isSelected ? Chrome.onTint : .secondaryLabelColor
    }
}
