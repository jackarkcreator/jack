// The 3.1 tool sheet: ONE attached sheet for every tool (Watermark, Bates, Crop, Lock, Clean,
// Compress, Make Searchable). Ratified mock: https://claude.ai/artifact/G29dCgBu8pYBZKujnrCTD1
//
// Anatomy (same for every tool): icon tile + title + one-line purpose · optional live preview
// on the left · labeled form rows on the right · an inline message line (problems show HERE,
// next to their cause, never as a second alert) · footer: what happens to the file (left),
// Cancel + one teal primary (right).
import AppKit

final class ToolSheet: NSObject {
    enum Tone { case hint, warn, error, ok }

    let window: NSWindow
    private let content: NSView
    private let iconTile = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let purposeLabel = NSTextField(wrappingLabelWithString: "")
    private let previewView = NSImageView()
    private var rows: [(label: NSTextField?, control: NSView)] = []
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let footerIcon = NSImageView()
    private let footerNote = NSTextField(wrappingLabelWithString: "")
    private let separator = NSBox()
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let primaryButton = NSButton(title: "OK", target: nil, action: nil)
    private weak var host: NSWindow?

    var onPrimary: (() -> Void)?
    var onCancel: (() -> Void)?
    let hasPreview: Bool

    static let width: CGFloat = 540
    private static let labelWidth: CGFloat = 92
    private static let previewSize = NSSize(width: 150, height: 194)

    init(symbol: String, title: String, purpose: String, note: (symbol: String, text: String),
         primary: String, preview: Bool) {
        hasPreview = preview
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
                          styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        content = window.contentView!
        super.init()

        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = 10
        let glyph = NSImageView(image: tinted(Chrome.symbol([symbol], title, .init(pointSize: 17, weight: .medium)) ?? NSImage(), Chrome.tint))
        glyph.frame = NSRect(x: 0, y: 0, width: 36, height: 36)
        glyph.imageAlignment = .alignCenter
        iconTile.addSubview(glyph)
        content.addSubview(iconTile)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        content.addSubview(titleLabel)
        purposeLabel.stringValue = purpose
        purposeLabel.font = .systemFont(ofSize: 12.5)
        purposeLabel.textColor = .secondaryLabelColor
        content.addSubview(purposeLabel)

        if preview {
            previewView.imageScaling = .scaleProportionallyUpOrDown
            previewView.wantsLayer = true
            previewView.layer?.shadowOpacity = 0.18
            previewView.layer?.shadowRadius = 4
            previewView.layer?.shadowOffset = CGSize(width: 0, height: -1)
            content.addSubview(previewView)
        }

        messageLabel.font = .systemFont(ofSize: 11.5)
        messageLabel.isHidden = true
        content.addSubview(messageLabel)

        separator.boxType = .separator
        content.addSubview(separator)
        footerIcon.image = Chrome.symbol([note.symbol], "", .init(pointSize: 11, weight: .medium))
        footerIcon.contentTintColor = .tertiaryLabelColor
        content.addSubview(footerIcon)
        footerNote.stringValue = note.text
        footerNote.font = .systemFont(ofSize: 11.5)
        footerNote.textColor = .tertiaryLabelColor
        content.addSubview(footerNote)

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        content.addSubview(cancelButton)
        primaryButton.title = primary
        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        primaryButton.bezelColor = Chrome.tint
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        content.addSubview(primaryButton)
        window.defaultButtonCell = primaryButton.cell as? NSButtonCell
    }

    // MARK: Building

    /// A labeled form row (label right-aligned in its own column; nil = no label).
    @discardableResult
    func addRow(_ label: String?, _ control: NSView) -> NSView {
        var l: NSTextField?
        if let label {
            let t = NSTextField(labelWithString: label)
            t.font = .systemFont(ofSize: 12.5)
            t.textColor = .secondaryLabelColor
            t.alignment = .right
            content.addSubview(t)
            l = t
        }
        content.addSubview(control)
        rows.append((l, control))
        return control
    }

    func setPreview(_ image: NSImage?) { previewView.image = image }

    func setMessage(_ text: String?, _ tone: Tone = .hint) {
        messageLabel.isHidden = (text ?? "").isEmpty
        messageLabel.stringValue = text ?? ""
        switch tone {
        case .hint: messageLabel.textColor = .tertiaryLabelColor
        case .warn: messageLabel.textColor = .systemOrange
        case .error: messageLabel.textColor = .systemRed
        case .ok: messageLabel.textColor = Chrome.tint
        }
        layout()
    }

    func setNote(symbol: String, _ text: String) {
        footerIcon.image = Chrome.symbol([symbol], "", .init(pointSize: 11, weight: .medium))
        footerNote.stringValue = text
        layout()
    }

    func setPrimary(_ title: String, enabled: Bool = true) {
        primaryButton.title = title
        primaryButton.isEnabled = enabled
        layout()
    }

    var primaryEnabled: Bool {
        get { primaryButton.isEnabled }
        set { primaryButton.isEnabled = newValue }
    }

    /// Long jobs: hide Cancel while running; on the result screen only Done remains.
    func setCancelVisible(_ visible: Bool) { cancelButton.isHidden = !visible; layout() }

    // MARK: Layout (top-down, sized to content)

    func layout() {
        let W = Self.width, pad: CGFloat = 22
        var y: CGFloat = 20   // from the top
        // header
        let purposeW = W - pad * 2 - 48
        purposeLabel.preferredMaxLayoutWidth = purposeW
        let purposeH = ceil(purposeLabel.intrinsicContentSize.height)
        let headerH = max(36, 19 + 3 + purposeH)
        y += headerH + 16
        // body
        let formX = hasPreview ? pad + Self.previewSize.width + 18 : pad
        let formW = W - formX - pad
        var formH: CGFloat = 0
        var rowFrames: [(NSTextField?, NSView, NSRect)] = []
        for (label, control) in rows {
            label?.isHidden = control.isHidden
            if control.isHidden { continue }
            var h = control.fittingSize.height
            if let tf = control as? NSTextField, !tf.isEditable { // wrapping labels
                tf.preferredMaxLayoutWidth = formW - (label == nil ? 0 : Self.labelWidth + 10)
                h = ceil(tf.intrinsicContentSize.height)
            }
            h = max(h, (control is NSTextField && (control as! NSTextField).isEditable) ? 24 : h)
            rowFrames.append((label, control, NSRect(x: 0, y: formH, width: 0, height: h)))
            formH += h + 10
        }
        var msgH: CGFloat = 0
        if !messageLabel.isHidden {
            messageLabel.preferredMaxLayoutWidth = formW - Self.labelWidth - 10
            msgH = ceil(messageLabel.intrinsicContentSize.height)
            formH += msgH + 4
        }
        let bodyH = max(hasPreview ? Self.previewSize.height : 0, formH)
        let footerH: CGFloat = 54
        let total = y + bodyH + 12 + footerH
        window.setContentSize(NSSize(width: W, height: total))
        let top = total   // convert top-down y to AppKit's bottom-up

        iconTile.frame = NSRect(x: pad, y: top - 20 - 36, width: 36, height: 36)
        iconTile.effectiveAppearance.performAsCurrentDrawingAppearance {
            iconTile.layer?.backgroundColor = Chrome.tintSoft.cgColor
        }
        titleLabel.frame = NSRect(x: pad + 48, y: top - 20 - 19, width: purposeW, height: 19)
        purposeLabel.frame = NSRect(x: pad + 48, y: top - 20 - 22 - purposeH, width: purposeW, height: purposeH)

        let bodyTop = top - y
        if hasPreview {
            previewView.frame = NSRect(x: pad, y: bodyTop - Self.previewSize.height,
                                       width: Self.previewSize.width, height: Self.previewSize.height)
        }
        for (label, control, f) in rowFrames {
            let rowTop = bodyTop - f.minY
            let controlX = label == nil && !(control is NSButton) ? formX : formX + Self.labelWidth + 10
            let cw = (control is NSButton && (control as! NSButton).bezelStyle != .rounded) || control is NSSegmentedControl
                ? min(control.fittingSize.width, formW - Self.labelWidth - 10)
                : formW - (controlX - formX)
            control.frame = NSRect(x: controlX, y: rowTop - f.height, width: max(cw, 10), height: f.height)
            label?.frame = NSRect(x: formX, y: rowTop - f.height + (f.height - 16) / 2, width: Self.labelWidth, height: 16)
        }
        if !messageLabel.isHidden {
            let my = bodyTop - (formH - msgH - 4)
            messageLabel.frame = NSRect(x: formX + Self.labelWidth + 10, y: my - msgH,
                                        width: formW - Self.labelWidth - 10, height: msgH)
        }

        separator.frame = NSRect(x: 0, y: footerH, width: W, height: 1)
        primaryButton.sizeToFit()
        cancelButton.sizeToFit()
        let pw = max(primaryButton.frame.width + 8, 84), cw = max(cancelButton.frame.width + 8, 84)
        primaryButton.frame = NSRect(x: W - pad - pw, y: 14, width: pw, height: 28)
        cancelButton.frame = NSRect(x: primaryButton.frame.minX - 10 - cw, y: 14, width: cw, height: 28)
        let noteRight = (cancelButton.isHidden ? primaryButton.frame.minX : cancelButton.frame.minX) - 14
        footerIcon.frame = NSRect(x: pad, y: 20, width: 14, height: 14)
        footerNote.preferredMaxLayoutWidth = noteRight - pad - 20
        let nh = min(ceil(footerNote.intrinsicContentSize.height), 30)
        footerNote.frame = NSRect(x: pad + 20, y: 27 - nh / 2, width: noteRight - pad - 20, height: nh)
    }

    // MARK: Presenting

    func present(on host: NSWindow) {
        self.host = host
        layout()
        host.beginSheet(window) { _ in }
        if let first = rows.first(where: { ($0.control as? NSTextField)?.isEditable == true })?.control {
            window.makeFirstResponder(first)
        }
    }

    func close() {
        if let host { host.endSheet(window) } else { window.orderOut(nil) }
    }

    @objc private func cancelClicked() { close(); onCancel?() }
    @objc private func primaryClicked() { onPrimary?() }

    // MARK: Helpers for forms

    static func field(_ value: String = "", placeholder: String? = nil, secure: Bool = false) -> NSTextField {
        let f: NSTextField = secure ? NSSecureTextField() : NSTextField()
        f.stringValue = value
        f.placeholderString = placeholder
        f.font = .systemFont(ofSize: 13)
        f.bezelStyle = .roundedBezel
        if #available(macOS 26.0, *) { f.borderShape = .roundedRectangle }
        return f
    }

    static func segmented(_ labels: [String], selected: Int) -> NSSegmentedControl {
        let s = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        s.selectedSegment = selected
        s.controlSize = .regular
        return s
    }

    static func note(_ text: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 12)
        t.textColor = .secondaryLabelColor
        return t
    }

    static func bigValue(_ text: String) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        t.font = .monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        return t
    }
}

/// Closure target for controls inside sheets (keeps actions next to the form that owns them).
final class ControlAction: NSObject {
    private let run: (Any?) -> Void
    init(_ run: @escaping (Any?) -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run(sender) }
    static var retained: [ControlAction] = []
    /// Wire `control`'s action to `run`; the action object lives as long as the app.
    static func bind(_ control: NSControl, _ run: @escaping (Any?) -> Void) {
        let a = ControlAction(run)
        retained.append(a)
        if retained.count > 200 { retained.removeFirst(retained.count - 200) }
        control.target = a
        control.action = #selector(fire(_:))
    }
}

/// Live typing → closure (NSTextField sends its action only on Return/end-editing).
final class TextChangeWatcher: NSObject {
    private var tokens: [NSObjectProtocol] = []
    func watch(_ field: NSTextField, _ run: @escaping () -> Void) {
        tokens.append(NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification,
                                                             object: field, queue: .main) { _ in run() })
    }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
