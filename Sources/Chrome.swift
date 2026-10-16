// The v3 chrome kit: every size, color, symbol and control the window chrome is built from.
// The document window, Organizer, Batch and the launcher all draw from here so they can't
// drift apart again. Ratified mock: https://claude.ai/artifact/5H3qFY8qz5KStt6RHyWyqC
//
// Shape rule: the toolbar uses capsules (native items); the work row uses rounded squares
// with CONCENTRIC corners (group 10 = tile 7 + inset 3). Color rule: Jack teal means
// "armed / has unsaved work"; either-or choices use a raised neutral selection.
import AppKit

enum Chrome {

    // MARK: Color

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { isDark($0) ? dark : light }
    }

    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }

    /// Jack teal: the app's one tint (armed tools, plates, menu checks, the filled Save).
    static let tint = dynamic("JackTint", light: rgb(0x0E6E6E), dark: rgb(0x2FBFAE))
    static let tintSoft = dynamic("JackTintSoft", light: rgb(0x0E6E6E, 0.13), dark: rgb(0x2FBFAE, 0.20))
    /// Text/icons drawn ON a filled tint.
    static let onTint = dynamic("JackOnTint", light: .white, dark: rgb(0x04231F))

    static let groupFill = dynamic("JackGroupFill", light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.07))
    static let groupStroke = dynamic("JackGroupStroke", light: NSColor(white: 0, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.10))
    static let hoverFill = dynamic("JackHoverFill", light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.07))
    static let pressFill = dynamic("JackPressFill", light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.12))
    /// The selected segment of an either-or choice.
    static let raised = dynamic("JackRaised", light: .white, dark: NSColor(white: 1, alpha: 0.17))
    /// The work row sits one step deeper than the title bar.
    static let trayFill = dynamic("JackTray", light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 0, alpha: 0.22))
    static let separator = dynamic("JackSeparator", light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.09))

    /// Tool labels: dark text on light reads heavier than light on dark, so light mode draws
    /// lighter and softer at the SAME size — switching appearance never moves a pixel.
    static let toolText = dynamic("JackToolText", light: rgb(0x43474E), dark: rgb(0xECECEF))
    static let toolIcon = dynamic("JackToolIcon", light: rgb(0x767B84), dark: rgb(0xA9A9B1))

    // MARK: Type (SF Pro, four roles; nothing below 11 pt, no uppercase labels)

    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let controlFont = NSFont.systemFont(ofSize: 13)
    static let metaFont = NSFont.systemFont(ofSize: 11)
    static func toolFont(for appearance: NSAppearance) -> NSFont {
        NSFont.systemFont(ofSize: 12, weight: isDark(appearance) ? .medium : NSFont.Weight(rawValue: 0.1))
    }
    static func modeFont(selected: Bool) -> NSFont {
        NSFont.systemFont(ofSize: 12.5, weight: selected ? .semibold : .medium)
    }

    // MARK: Symbols (a glyph never exceeds ~60% of its control's height)

    static let toolbarSymbol = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular, scale: .medium)
    static let stripSymbol = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular, scale: .medium)
    static let pillSymbol = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium, scale: .small)
    static let menuSymbol = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular, scale: .medium)

    static func symbol(_ candidates: [String], _ label: String,
                       _ config: NSImage.SymbolConfiguration = stripSymbol) -> NSImage? {
        for name in candidates {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: label) {
                return img.withSymbolConfiguration(config) ?? img
            }
        }
        return nil
    }

    // MARK: Metrics

    static let workRowHeight: CGFloat = 44
    static let groupHeight: CGFloat = 30
    static let groupInset: CGFloat = 3
    static let groupRadius: CGFloat = 10
    static let tileHeight: CGFloat = 24
    static let tileRadius: CGFloat = 7          // = groupRadius - groupInset (concentric)
    static let leadingEdge: CGFloat = 16        // the traffic-light line
    static let trailingEdge: CGFloat = 12       // Save's right edge
    /// Below this window width every tool group drops its labels together.
    static let labelBreakpoint: CGFloat = 1000
}

// MARK: - Tool tile

/// One tool in a work-row group: SF Symbol + label (label hidden on narrow windows).
/// `isArmed` is the teal "this tool is active" state; the controller owns it.
final class ToolTile: NSButton {
    var isArmed = false { didSet { if isArmed != oldValue { needsDisplay = true; setAccessibilityValue(isArmed ? "on" : nil) } } }
    var showsLabel = true { didSet { if showsLabel != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    /// Momentary tiles that open a menu (Sign) draw a small chevron.
    var showsMenuIndicator = false
    private var hovering = false
    private let label: String

    init(symbol: [String], label: String, tip: String, target: AnyObject?, action: Selector?) {
        self.label = label
        super.init(frame: .zero)
        self.title = label
        self.image = Chrome.symbol(symbol, label)
        self.image?.isTemplate = true
        self.target = target
        self.action = action
        self.isBordered = false
        self.setButtonType(.momentaryChange)
        self.toolTip = tip
        self.setAccessibilityLabel(label)
        self.setAccessibilityHelp(tip)
        self.focusRingType = .default
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let iconW: CGFloat = 16
        guard showsLabel else { return NSSize(width: 30, height: Chrome.tileHeight) }
        let w = (label as NSString).size(withAttributes: [.font: Chrome.toolFont(for: effectiveAppearance)]).width
        return NSSize(width: ceil(9 + iconW + 6 + w + 9 + (showsMenuIndicator ? 10 : 0)), height: Chrome.tileHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { invalidateIntrinsicContentSize(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let r = bounds
            let plate = NSBezierPath(roundedRect: r, xRadius: Chrome.tileRadius, yRadius: Chrome.tileRadius)
            if isArmed { Chrome.tintSoft.setFill(); plate.fill() }
            else if isHighlighted { Chrome.pressFill.setFill(); plate.fill() }
            else if hovering && isEnabled { Chrome.hoverFill.setFill(); plate.fill() }

            let textColor: NSColor = !isEnabled ? .tertiaryLabelColor : (isArmed ? Chrome.tint : Chrome.toolText)
            let iconColor: NSColor = !isEnabled ? .tertiaryLabelColor : (isArmed ? Chrome.tint : (hovering ? Chrome.toolText : Chrome.toolIcon))
            let iconBox: CGFloat = 16
            let iconX = showsLabel ? 9 : (r.width - iconBox) / 2
            if let img = image {
                let s = img.size
                let scale = min(iconBox / max(s.width, 1), iconBox / max(s.height, 1), 1)
                let w = s.width * scale, h = s.height * scale
                let rect = NSRect(x: iconX + (iconBox - w) / 2, y: (r.height - h) / 2, width: w, height: h)
                tinted(img, iconColor).draw(in: rect)
            }
            if showsLabel {
                let font = Chrome.toolFont(for: effectiveAppearance)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
                let size = (label as NSString).size(withAttributes: attrs)
                (label as NSString).draw(at: NSPoint(x: iconX + iconBox + 6, y: (r.height - size.height) / 2), withAttributes: attrs)
                if showsMenuIndicator, let chev = Chrome.symbol(["chevron.down"], "", .init(pointSize: 8, weight: .semibold)) {
                    let cs = chev.size
                    tinted(chev, iconColor).draw(in: NSRect(x: r.width - 9 - cs.width, y: (r.height - cs.height) / 2,
                                                            width: cs.width, height: cs.height))
                }
            }
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Chrome.tileRadius, yRadius: Chrome.tileRadius).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// A template image filled with `color` (template images ignore fill color when drawn directly).
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    out.isTemplate = false
    return out
}

// MARK: - Group (rounded square that holds tiles or segments)

final class ToolGroupView: NSView {
    private(set) var items: [NSView]

    init(items: [NSView], label: String) {
        self.items = items
        super.init(frame: .zero)
        items.forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
        relayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Size to the items' intrinsic widths and lay them out left to right.
    func relayout() {
        var x = Chrome.groupInset
        for v in items {
            let w = v.intrinsicContentSize.width
            v.frame = NSRect(x: x, y: Chrome.groupInset, width: w, height: Chrome.tileHeight)
            x += w + 2
        }
        setFrameSize(NSSize(width: x - 2 + Chrome.groupInset, height: Chrome.groupHeight))
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: Chrome.groupRadius, yRadius: Chrome.groupRadius)
            Chrome.groupFill.setFill(); p.fill()
            Chrome.groupStroke.setStroke(); p.lineWidth = 0.5; p.stroke()
        }
    }
}

// MARK: - Mode switch (Read · Markup · Redact): an either-or choice, raised neutral selection

final class ModeSwitch: NSView {
    private(set) var selectedIndex = 0
    private var segments: [SegmentButton] = []
    private var group: ToolGroupView!
    var onChange: ((Int) -> Void)?

    init(titles: [String], tips: [String]) {
        super.init(frame: .zero)
        segments = titles.enumerated().map { i, t in
            let b = SegmentButton(title: t, index: i, owner: self)
            b.toolTip = tips[i]
            return b
        }
        group = ToolGroupView(items: segments, label: "Mode")
        addSubview(group)
        setFrameSize(group.frame.size)
        select(0)
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(_ i: Int) {
        selectedIndex = i
        for (n, s) in segments.enumerated() {
            s.isSelected = n == i
            s.setAccessibilityValue(n == i ? 1 : 0)
        }
    }

    fileprivate func segmentClicked(_ i: Int) {
        guard i != selectedIndex else { return }
        select(i)
        onChange?(i)
    }

    final class SegmentButton: NSButton {
        let index: Int
        weak var owner: ModeSwitch?
        var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
        private let text: String

        init(title: String, index: Int, owner: ModeSwitch) {
            self.index = index; self.owner = owner; self.text = title
            super.init(frame: .zero)
            self.title = title
            isBordered = false
            setButtonType(.momentaryChange)
            target = self
            action = #selector(clicked)
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(title)
        }
        required init?(coder: NSCoder) { fatalError() }
        @objc private func clicked() { owner?.segmentClicked(index) }

        override var intrinsicContentSize: NSSize {
            let w = (text as NSString).size(withAttributes: [.font: Chrome.modeFont(selected: true)]).width
            return NSSize(width: ceil(w + 28), height: Chrome.tileHeight)
        }

        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                if isSelected {
                    let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Chrome.tileRadius, yRadius: Chrome.tileRadius)
                    NSGraphicsContext.saveGraphicsState()
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor(white: 0, alpha: 0.18)
                    shadow.shadowOffset = NSSize(width: 0, height: -1)
                    shadow.shadowBlurRadius = 2
                    shadow.set()
                    Chrome.raised.setFill(); p.fill()
                    NSGraphicsContext.restoreGraphicsState()
                    Chrome.groupStroke.setStroke(); p.lineWidth = 0.5; p.stroke()
                } else if isHighlighted {
                    Chrome.pressFill.setFill()
                    NSBezierPath(roundedRect: bounds, xRadius: Chrome.tileRadius, yRadius: Chrome.tileRadius).fill()
                }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: Chrome.modeFont(selected: isSelected),
                    .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor]
                let s = (text as NSString).size(withAttributes: attrs)
                (text as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2),
                                        withAttributes: attrs)
            }
        }
    }
}

// MARK: - Small pieces

/// The hairline between zones in the work row.
final class ZoneDivider: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 18) }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { Chrome.separator.setFill(); bounds.fill() }
    }
}

/// A color choice in the Options zone (highlight / ink colors).
final class SwatchButton: NSButton {
    let color: NSColor
    var isChosen = false { didSet { needsDisplay = true; setAccessibilityValue(isChosen ? 1 : 0) } }
    init(color: NSColor, name: String, target: AnyObject?, action: Selector?) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        isBordered = false
        title = ""
        self.target = target
        self.action = action
        toolTip = name
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(name)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let c = NSRect(x: 3, y: 3, width: 16, height: 16)
            if isChosen {
                Chrome.tint.setStroke()
                let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75)); ring.lineWidth = 1.5; ring.stroke()
            }
            color.setFill(); NSBezierPath(ovalIn: c).fill()
            NSColor(white: 0, alpha: 0.25).setStroke()
            let edge = NSBezierPath(ovalIn: c.insetBy(dx: 0.25, dy: 0.25)); edge.lineWidth = 0.5; edge.stroke()
        }
    }
}

/// Lays views out left to right with fixed gaps, vertically centered (the work-row zones).
final class HStackRow: NSView {
    var gap: CGFloat = 4
    private(set) var arranged: [NSView] = []
    /// Per-view extra spacing BEFORE that view (dividers get 8 on each side).
    private var extra: [ObjectIdentifier: CGFloat] = [:]

    func set(_ views: [NSView], spacingBefore: [ObjectIdentifier: CGFloat] = [:]) {
        arranged.forEach { $0.removeFromSuperview() }
        arranged = views
        extra = spacingBefore
        views.forEach(addSubview)
        relayout()
    }

    func relayout() {
        var x: CGFloat = 0
        var first = true
        for v in arranged where !v.isHidden {
            if !first { x += gap }
            x += extra[ObjectIdentifier(v)] ?? 0
            first = false
            var size = v.frame.size
            let intrinsic = v.intrinsicContentSize
            if intrinsic.width != NSView.noIntrinsicMetric { size.width = intrinsic.width }
            if intrinsic.height != NSView.noIntrinsicMetric { size.height = intrinsic.height }
            v.frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width
        }
        contentWidth = x
    }
    private(set) var contentWidth: CGFloat = 0
    override func resizeSubviews(withOldSize oldSize: NSSize) { super.resizeSubviews(withOldSize: oldSize); relayout() }
}

// MARK: - Page pill (bottom-center): ‹ Page n of N › | − 100% ⌄ +

/// A round, borderless control for the page pill.
final class PillButton: NSButton {
    private var hovering = false
    var text: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var showsChevron = false
    var isOpen = false { didSet { needsDisplay = true } }

    init(symbol: String?, label: String, target: AnyObject?, action: Selector?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        title = ""
        if let symbol { image = Chrome.symbol([symbol], label, Chrome.pillSymbol) }
        isBordered = false
        setButtonType(.momentaryChange)
        self.target = target
        self.action = action
        toolTip = label
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        guard let text else { return NSSize(width: 28, height: 28) }
        let w = (text as NSString).size(withAttributes: [.font: Self.font]).width
        return NSSize(width: ceil(w + 18 + (showsChevron ? 12 : 0)), height: 28)
    }
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let plate = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            if isOpen { Chrome.tintSoft.setFill(); plate.fill() }
            else if isHighlighted { Chrome.pressFill.setFill(); plate.fill() }
            else if hovering && isEnabled { Chrome.hoverFill.setFill(); plate.fill() }
            let fg: NSColor = !isEnabled ? .tertiaryLabelColor : (isOpen ? Chrome.tint : (hovering ? .labelColor : .secondaryLabelColor))
            if let text {
                let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: isOpen ? Chrome.tint : NSColor.labelColor]
                let s = (text as NSString).size(withAttributes: attrs)
                (text as NSString).draw(at: NSPoint(x: 9, y: (bounds.height - s.height) / 2), withAttributes: attrs)
                if showsChevron, let chev = Chrome.symbol(["chevron.down"], "", .init(pointSize: 8, weight: .bold)) {
                    let cs = chev.size
                    tinted(chev, fg).draw(in: NSRect(x: bounds.width - 9 - cs.width, y: (bounds.height - cs.height) / 2,
                                                     width: cs.width, height: cs.height))
                }
            } else if let img = image {
                let s = img.size
                tinted(img, fg).draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2,
                                                width: s.width, height: s.height))
            }
        }
    }
}

/// The floating page + zoom control. Glass on Tahoe, menu material before it.
final class PagePill: NSView {
    let prev = PillButton(symbol: "chevron.left", label: "Previous page", target: nil, action: nil)
    let next = PillButton(symbol: "chevron.right", label: "Next page", target: nil, action: nil)
    let zoomOut = PillButton(symbol: "minus", label: "Zoom out (\u{2318}\u{2212})", target: nil, action: nil)
    let zoomIn = PillButton(symbol: "plus", label: "Zoom in (\u{2318}+)", target: nil, action: nil)
    let zoomMenuButton = PillButton(symbol: nil, label: "Zoom and page layout", target: nil, action: nil)
    private let pageLabel = NSTextField(labelWithString: "")
    private let divider = ZoneDivider()
    private let content = NSView()
    private var background: NSView!

    override init(frame: NSRect) {
        super.init(frame: frame)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 17
            glass.contentView = content
            background = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .menu
            fx.blendingMode = .withinWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 17
            fx.layer?.masksToBounds = true
            fx.addSubview(content)
            background = fx
        }
        addSubview(background)
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor(white: 0, alpha: 0.22)
            s.shadowBlurRadius = 12
            s.shadowOffset = NSSize(width: 0, height: -3)
            return s
        }()
        pageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pageLabel.textColor = .labelColor
        zoomMenuButton.showsChevron = true
        zoomMenuButton.text = "100%"
        [prev, pageLabel, next, divider, zoomOut, zoomMenuButton, zoomIn].forEach(content.addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Page and zoom")
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(page: Int, of count: Int, percent: Int) {
        pageLabel.stringValue = "Page \(page) of \(count)"
        zoomMenuButton.text = "\(percent)%"
        prev.isEnabled = page > 1
        next.isEnabled = page < count
        relayout()
    }

    /// Lays out the pieces and sizes the pill to fit them.
    func relayout() {
        var x: CGFloat = 3
        func place(_ v: NSView, _ w: CGFloat, _ h: CGFloat) {
            v.frame = NSRect(x: x, y: ((34 - h) / 2).rounded(), width: w, height: h)
            x += w
        }
        place(prev, 28, 28)
        x += 4
        pageLabel.sizeToFit()
        place(pageLabel, ceil(pageLabel.frame.width), ceil(pageLabel.frame.height))
        x += 4
        place(next, 28, 28)
        x += 6
        place(divider, 1, 16)
        x += 6
        place(zoomOut, 28, 28)
        place(zoomMenuButton, zoomMenuButton.intrinsicContentSize.width, 28)
        place(zoomIn, 28, 28)
        x += 3
        setFrameSize(NSSize(width: x, height: 34))
        background.frame = bounds
        content.frame = bounds
    }
}

// MARK: - Menu-bar glyph

extension Chrome {
    /// Paper Jack for the menu bar: the app icon's sheet (folded top-right corner) and face,
    /// as an 18 pt TEMPLATE image so macOS tints it like every other menu-bar item. Drawn in
    /// vector at any scale, so it stays crisp on every display.
    static func menuBarGlyph() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            // Sheet: rounded corners, top-right folded away.
            let sheet = NSBezierPath()
            sheet.move(to: NSPoint(x: 5.5, y: 1.75))
            sheet.line(to: NSPoint(x: 12.5, y: 1.75))
            sheet.curve(to: NSPoint(x: 14.25, y: 3.5), controlPoint1: NSPoint(x: 13.6, y: 1.75), controlPoint2: NSPoint(x: 14.25, y: 2.4))
            sheet.line(to: NSPoint(x: 14.25, y: 12.25))
            sheet.line(to: NSPoint(x: 10.25, y: 16.25))
            sheet.line(to: NSPoint(x: 5.5, y: 16.25))
            sheet.curve(to: NSPoint(x: 3.75, y: 14.5), controlPoint1: NSPoint(x: 4.4, y: 16.25), controlPoint2: NSPoint(x: 3.75, y: 15.6))
            sheet.line(to: NSPoint(x: 3.75, y: 3.5))
            sheet.curve(to: NSPoint(x: 5.5, y: 1.75), controlPoint1: NSPoint(x: 3.75, y: 2.4), controlPoint2: NSPoint(x: 4.4, y: 1.75))
            sheet.close()
            sheet.lineWidth = 1.4
            sheet.lineJoinStyle = .round
            sheet.stroke()
            // The fold: a small solid flap.
            let flap = NSBezierPath()
            flap.move(to: NSPoint(x: 10.25, y: 16.25))
            flap.line(to: NSPoint(x: 10.25, y: 13.25))
            flap.curve(to: NSPoint(x: 11.25, y: 12.25), controlPoint1: NSPoint(x: 10.25, y: 12.7), controlPoint2: NSPoint(x: 10.7, y: 12.25))
            flap.line(to: NSPoint(x: 14.25, y: 12.25))
            flap.close()
            flap.fill()
            // Face: two eyes and a small smile.
            NSBezierPath(ovalIn: NSRect(x: 6.35, y: 8.0, width: 1.7, height: 2.4)).fill()
            NSBezierPath(ovalIn: NSRect(x: 9.95, y: 8.0, width: 1.7, height: 2.4)).fill()
            let smile = NSBezierPath()
            smile.move(to: NSPoint(x: 6.6, y: 6.0))
            smile.curve(to: NSPoint(x: 11.4, y: 6.0), controlPoint1: NSPoint(x: 7.6, y: 4.2), controlPoint2: NSPoint(x: 10.4, y: 4.2))
            smile.lineWidth = 1.3
            smile.lineCapStyle = .round
            smile.stroke()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Jack"
        return img
    }
}
