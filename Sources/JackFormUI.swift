// Jack's own form-field rendering — the approved Form Kit mock, drawn to the pixel.
//
// PDFKit's native widget chrome is what made forms look dated (hover-only highlights,
// flat inset boxes, NSMenu combos). Jack now renders supported widgets itself in the
// page draw path, so fields look right on screen, in thumbnails, and at any zoom —
// while the file underneath stays 100% standard AcroForm for every other reader.
//
// Spec (ratified 2026-08-30, "Jack Form Kit" artifact): 6pt radius, 1pt #C9CDD3 hairline
// on white, systemBlue accent, 18pt checks/radios, accent dropdown pill, captions beside
// controls optically centered. Selection ring + 4 corner handles in build mode.
import AppKit
import PDFKit

enum JackFormUI {
    /// Master switch. Keno pulled Forms from the product 2026-08-30 after the authoring
    /// UX failed hands-on twice; the kit stays in the codebase behind this hidden pref
    /// (`defaults write net.thinkopen.jack jack.formsEnabled -bool YES`) for the next run.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "jack.formsEnabled") }

    // MARK: Spec tokens
    static let border = NSColor(calibratedRed: 0.788, green: 0.804, blue: 0.827, alpha: 1)  // #C9CDD3
    static let accent = NSColor(calibratedRed: 0.039, green: 0.518, blue: 1.0, alpha: 1)    // #0A84FF
    static let valueInk = NSColor(calibratedRed: 0.114, green: 0.114, blue: 0.122, alpha: 1) // #1D1D1F
    static let placeholderInk = NSColor(calibratedRed: 0.604, green: 0.604, blue: 0.627, alpha: 1) // #9A9AA0
    static let radius: CGFloat = 6
    static let checkSide: CGFloat = 18

    /// Placeholders ("Type here") are VIEW candy — they must never reach a flatten,
    /// raster, OCR render, or export. SigningPDFView arms this only for the duration of
    /// its own display drawing; every other page.draw caller sees it off.
    static var placeholdersEnabled = false

    /// Widget kinds Jack renders and drives itself. Everything else (signatures, list
    /// boxes, JS-driven exotica) keeps PDFKit's default look and behavior.
    static func isSupported(_ a: PDFAnnotation) -> Bool {
        guard a.type == "Widget" else { return false }
        switch a.widgetFieldType {
        case .text: return true
        case .button:
            return a.widgetControlType == .checkBoxControl || a.widgetControlType == .radioButtonControl
        case .choice: return !a.isListChoice        // combo yes, list box no
        default: return false
        }
    }

    // MARK: Chrome

    static func drawChrome(for a: PDFAnnotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let b = a.bounds
        switch a.widgetFieldType {
        case .button:
            drawToggle(a, in: ctx)
        case .choice:
            drawBox(b, in: ctx)
            drawValueText(a, in: ctx, trailingInset: 26)
            drawComboPill(b, in: ctx)
        default:
            drawBox(b, in: ctx)
            drawValueText(a, in: ctx, trailingInset: isDateStyled(a) ? 26 : 8)
            if isDateStyled(a) { drawCalendarGlyph(b, in: ctx) }
        }
    }

    /// The date marker lives in the caption link (see FormFieldEngine.isDateField); the
    /// renderer only needs a cheap check, so it scans the page's labels once per draw.
    private static func isDateStyled(_ a: PDFAnnotation) -> Bool {
        guard a.widgetFieldType == .text, let page = a.page, let name = a.fieldName else { return false }
        return FormFieldEngine.isDateField(a, on: page) || name.lowercased().hasPrefix("date")
    }

    private static func drawBox(_ b: CGRect, in ctx: CGContext) {
        // Overpaint PDFKit's square widget render first, then lay the rounded chrome.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(b.insetBy(dx: -1.2, dy: -1.2))
        let path = CGPath(roundedRect: b, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(border.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    private static func drawValueText(_ a: PDFAnnotation, in ctx: CGContext, trailingInset: CGFloat) {
        let value = (a.widgetStringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let showPlaceholder = value.isEmpty && placeholdersEnabled
        guard !value.isEmpty || showPlaceholder else { return }
        let size = min(a.font?.pointSize ?? 13, max(9, a.bounds.height - 12))
        let font = a.font.flatMap { NSFont(descriptor: $0.fontDescriptor, size: size) } ?? .systemFont(ofSize: size)
        let text = value.isEmpty ? "Type here" : value
        let color = value.isEmpty ? placeholderInk : valueInk
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        ctx.clip(to: a.bounds.insetBy(dx: 2, dy: 0))
        if a.isMultiline && !value.isEmpty {
            let fs = CTFramesetterCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
            let path = CGPath(rect: a.bounds.insetBy(dx: 8, dy: 7), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil), ctx)
        } else {
            let y = a.isMultiline ? a.bounds.maxY - 7 - font.ascender
                                  : a.bounds.midY - (font.ascender + font.descender) / 2
            ctx.textPosition = CGPoint(x: a.bounds.minX + 10, y: y)
            _ = trailingInset   // clip already bounds the draw; inset documents intent
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }

    private static func drawToggle(_ a: PDFAnnotation, in ctx: CGContext) {
        let side = min(max(min(a.bounds.width, a.bounds.height), 12), 40)
        let box = CGRect(x: a.bounds.minX, y: a.bounds.midY - side / 2, width: side, height: side)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(a.bounds.insetBy(dx: -1.2, dy: -1.2))
        let on = a.buttonWidgetState == .onState
        let isRadio = a.widgetControlType == .radioButtonControl
        if isRadio {
            let circle = CGPath(ellipseIn: box, transform: nil)
            ctx.addPath(circle); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
            ctx.addPath(circle)
            ctx.setStrokeColor(on ? accent.cgColor : border.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            if on {
                let d = side * 8.0 / 18.0
                ctx.setFillColor(accent.cgColor)
                ctx.fillEllipse(in: CGRect(x: box.midX - d / 2, y: box.midY - d / 2, width: d, height: d))
            }
        } else {
            let r = side * 5.0 / 18.0
            let path = CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(on ? accent.cgColor : NSColor.white.cgColor)
            ctx.fillPath()
            if !on {
                ctx.addPath(path)
                ctx.setStrokeColor(border.cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()
            } else {
                // White check, 2.4pt, proportional to the box.
                let s = side / 18.0
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(2.4 * s)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.move(to: CGPoint(x: box.minX + 4.2 * s, y: box.minY + 9.0 * s))
                ctx.addLine(to: CGPoint(x: box.minX + 7.6 * s, y: box.minY + 5.4 * s))
                ctx.addLine(to: CGPoint(x: box.minX + 13.8 * s, y: box.minY + 12.8 * s))
                ctx.strokePath()
            }
        }
    }

    private static func drawComboPill(_ b: CGRect, in ctx: CGContext) {
        let side: CGFloat = 18
        let pill = CGRect(x: b.maxX - side - 5, y: b.midY - side / 2, width: side, height: side)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.setFillColor(accent.cgColor)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.8)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let cx = pill.midX
        ctx.move(to: CGPoint(x: cx - 3.2, y: pill.midY + 2.2))
        ctx.addLine(to: CGPoint(x: cx, y: pill.midY + 5.2))
        ctx.addLine(to: CGPoint(x: cx + 3.2, y: pill.midY + 2.2))
        ctx.move(to: CGPoint(x: cx - 3.2, y: pill.midY - 2.2))
        ctx.addLine(to: CGPoint(x: cx, y: pill.midY - 5.2))
        ctx.addLine(to: CGPoint(x: cx + 3.2, y: pill.midY - 2.2))
        ctx.strokePath()
    }

    private static func drawCalendarGlyph(_ b: CGRect, in ctx: CGContext) {
        let s: CGFloat = 14
        let g = CGRect(x: b.maxX - s - 8, y: b.midY - s / 2, width: s, height: s)
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.56, alpha: 1).cgColor)
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)
        ctx.addPath(CGPath(roundedRect: g.insetBy(dx: 0.6, dy: 1.2), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        ctx.move(to: CGPoint(x: g.minX + 0.6, y: g.maxY - 5))
        ctx.addLine(to: CGPoint(x: g.maxX - 0.6, y: g.maxY - 5))
        ctx.move(to: CGPoint(x: g.minX + 4, y: g.maxY - 1))
        ctx.addLine(to: CGPoint(x: g.minX + 4, y: g.maxY + 0.8))
        ctx.move(to: CGPoint(x: g.maxX - 4, y: g.maxY - 1))
        ctx.addLine(to: CGPoint(x: g.maxX - 4, y: g.maxY + 0.8))
        ctx.strokePath()
    }

    /// Corner handle rects in page space (ring corners): NW, NE, SW, SE.
    static func handleRects(for b: CGRect) -> [CGRect] {
        let ring = b.insetBy(dx: -4, dy: -4)
        let h: CGFloat = 8
        return [CGPoint(x: ring.minX, y: ring.maxY), CGPoint(x: ring.maxX, y: ring.maxY),
                CGPoint(x: ring.minX, y: ring.minY), CGPoint(x: ring.maxX, y: ring.minY)]
            .map { CGRect(x: $0.x - h / 2, y: $0.y - h / 2, width: h, height: h) }
    }

    /// The SE handle drives resize (spec); a fat hit area keeps it grabbable.
    static func seHandleHit(for b: CGRect) -> CGRect {
        handleRects(for: b)[3].insetBy(dx: -5, dy: -5)
    }
}

/// Every page in a Jack document renders through this subclass, so field chrome shows in
/// the view, in thumbnails, and in flattens — but placeholders only during live display.
final class JackPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        guard JackFormUI.enabled else { return }   // widgets stay PDFKit-native when Forms is off
        for a in annotations where JackFormUI.isSupported(a) {
            JackFormUI.drawChrome(for: a, in: context)
        }
    }
}
