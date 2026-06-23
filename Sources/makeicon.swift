// Renders Jack's 1024×1024 app icon to PNG using CoreGraphics/AppKit (no external rasterizer needed).
// Concept: a fanned stack of photos collapsing through a teal merge-arrow into a single PDF page.
// Coordinates are bottom-left origin (native AppKit) so text draws upright.
import Cocoa

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

let px = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Squircle background, navy → deep-teal diagonal gradient.
let squircle = rrect(100, 100, 824, 824, 180)
let bg = NSGradient(starting: rgb(10, 37, 64), ending: rgb(14, 61, 82))
bg?.draw(in: squircle, angle: -45)

// Fanned photo stack (back → front, offset down-right).
let cardR: CGFloat = 30
rgb(255, 255, 255, 0.45).setFill(); rrect(210, 430, 200, 200, cardR).fill()
rgb(255, 255, 255, 0.75).setFill(); rrect(245, 398, 200, 200, cardR).fill()
rgb(255, 255, 255, 1.00).setFill(); rrect(280, 366, 200, 200, cardR).fill()

// Photo content on the front card: teal sky + amber sun + light ground.
rgb(205, 216, 220).setFill(); rrect(302, 388, 156, 70, 8).fill()   // ground
rgb(14, 110, 110).setFill();  rrect(302, 462, 156, 82, 8).fill()   // sky
rgb(245, 166, 35).setFill()
NSBezierPath(ovalIn: NSRect(x: 408, y: 478, width: 44, height: 44)).fill() // sun

// Teal merge arrow (chevron pointing right).
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 505, y: 580))
arrow.line(to: NSPoint(x: 562, y: 512))
arrow.line(to: NSPoint(x: 505, y: 444))
arrow.lineWidth = 28
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
rgb(20, 184, 166).setStroke()
arrow.stroke()

// PDF page (white) with amber folded corner.
rgb(255, 255, 255).setFill(); rrect(590, 352, 230, 320, 28).fill()
rgb(245, 166, 35).setFill()
let fold = NSBezierPath()
fold.move(to: NSPoint(x: 760, y: 672))
fold.line(to: NSPoint(x: 820, y: 672))
fold.line(to: NSPoint(x: 820, y: 612))
fold.close(); fold.fill()

// Text lines on the page.
rgb(159, 176, 184).setFill()
rrect(625, 600, 140, 18, 9).fill()
rrect(625, 560, 160, 18, 9).fill()
rrect(625, 520, 100, 18, 9).fill()

// "PDF" wordmark.
let para = NSMutableParagraphStyle(); para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 66, weight: .bold),
    .foregroundColor: rgb(10, 37, 64),
    .paragraphStyle: para
]
NSString(string: "PDF").draw(in: NSRect(x: 590, y: 408, width: 230, height: 80), withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "jack-1024.png"
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try? png.write(to: URL(fileURLWithPath: outPath))
