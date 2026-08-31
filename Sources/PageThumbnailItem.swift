// One page tile in the Page Organizer: thumbnail + page number, with a selection ring.
import AppKit

final class PageThumbnailItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("PageThumbnailItem")

    private let thumb = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let dash = CAShapeLayer()   // the empty-slot outline (taken mode)

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 150, height: 196))
        v.wantsLayer = true
        v.layer?.cornerRadius = 6

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
        label.textColor = .secondaryLabelColor
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
        view.layer?.borderWidth = isSelected ? 3 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}
