// Renders Jack's app icon into a .iconset using CoreGraphics (no external rasterizer or image files).
// Concept (v3.0, "Paper Jack · Navy"): an upright sheet of paper with an amber dog-ear and a calm
// two-eyed face, on a navy squircle lit by a teal glow from below.
// Every size is drawn natively, never downscaled: 16 px and 32 px use hand-placed, pixel-snapped
// geometry so they stay crisp in Finder lists and menus.
// Coordinates are a 1024-unit design space, bottom-left origin; the body sits on Apple's 824-unit grid.
// Usage: makeicon <dir.iconset>   (or makeicon <file.png> for a single 1024 px render)
import Cocoa

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
let navy: UInt32 = 0x0A2540, navyHi: UInt32 = 0x163A5C, tealHi: UInt32 = 0x14B8A6, amber: UInt32 = 0xF5A623
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// Apple-style continuous squircle, approximated by a superellipse (n = 5).
func squircle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi, ct = cos(t), st = sin(t)
        let pt = CGPoint(x: cx + r * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n),
                         y: cy + r * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath(); return p
}

// Fills `path` with a vertical gradient, `top` at yTop and `bottom` at yBottom.
func vertical(_ ctx: CGContext, _ path: CGPath, _ top: CGColor, _ bottom: CGColor, _ yTop: CGFloat, _ yBottom: CGFloat) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: sRGB, colors: [bottom, top] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: yBottom), end: CGPoint(x: 0, y: yTop),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

struct Sheet { var cx, cy, w, h, r, fold: CGFloat }

// Sheet outline with the top-right corner folded away.
func sheetPath(_ p: Sheet) -> CGPath {
    let x0 = p.cx - p.w / 2, x1 = p.cx + p.w / 2, y0 = p.cy - p.h / 2, y1 = p.cy + p.h / 2
    let m = CGMutablePath()
    m.move(to: CGPoint(x: x0 + p.r, y: y0))
    m.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y1), radius: p.r)
    m.addArc(tangent1End: CGPoint(x: x1, y: y1 - p.fold), tangent2End: CGPoint(x: x1 - p.fold, y: y1), radius: p.r * 0.45)
    m.addArc(tangent1End: CGPoint(x: x1 - p.fold, y: y1), tangent2End: CGPoint(x: x0, y: y1), radius: p.r * 0.45)
    m.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y0), radius: p.r)
    m.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x1, y: y0), radius: p.r)
    m.closeSubpath(); return m
}

// The folded-over flap (its amber back faces us).
func flapPath(_ p: Sheet) -> CGPath {
    let x1 = p.cx + p.w / 2, y1 = p.cy + p.h / 2, f = p.fold
    let m = CGMutablePath()
    m.move(to: CGPoint(x: x1 - f, y: y1))
    m.addArc(tangent1End: CGPoint(x: x1 - f, y: y1 - f), tangent2End: CGPoint(x: x1, y: y1 - f), radius: p.r * 0.9)
    m.addLine(to: CGPoint(x: x1, y: y1 - f))
    m.closeSubpath(); return m
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let s = CGFloat(px) / 1024, u = 1024 / CGFloat(px)   // u = one device pixel in design units
    ctx.scaleBy(x: s, y: s)
    let small = px <= 32, tiny = px <= 16
    let body = squircle(512, 512, 412)

    // Navy squircle, lighter at the top, with a teal glow rising from the bottom edge.
    // The glow is stronger at small sizes so the icon never reads as a dark square in a dark Dock.
    vertical(ctx, body, color(navyHi), color(navy), 924, 100)
    ctx.saveGState(); ctx.addPath(body); ctx.clip()
    let glow = CGGradient(colorsSpace: sRGB, colors: [color(tealHi, small ? 0.95 : 0.75), color(tealHi, 0)] as CFArray,
                          locations: [0, 1])!
    let glowAt = CGPoint(x: 512, y: small ? 120 : 130)
    ctx.drawRadialGradient(glow, startCenter: glowAt, startRadius: 0, endCenter: glowAt, endRadius: small ? 640 : 600, options: [])
    ctx.restoreGState()
    // Glass rim: soft top light and a faint inner edge (sub-pixel below 64 px, so skipped there).
    if !small {
        ctx.saveGState(); ctx.addPath(body); ctx.clip()
        let sheen = CGGradient(colorsSpace: sRGB, colors: [color(0xFFFFFF, 0), color(0xFFFFFF, 0.16)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 560), end: CGPoint(x: 0, y: 924), options: [])
        ctx.addPath(body); ctx.setStrokeColor(color(0xFFFFFF, 0.28)); ctx.setLineWidth(6); ctx.strokePath()
        ctx.restoreGState()
    }

    // The sheet. Small sizes snap every edge to whole pixels.
    var sheet = Sheet(cx: 512, cy: 500, w: 450, h: 580, r: 40, fold: 150)
    if tiny { sheet = Sheet(cx: 512, cy: 512, w: 8 * u, h: 10 * u, r: 0.8 * u, fold: 3 * u) }        // x 4…12, y 3…13 px
    else if small { sheet = Sheet(cx: 512, cy: 512, w: 16 * u, h: 20 * u, r: 1.4 * u, fold: 6 * u) } // x 8…24, y 6…26 px
    let top = sheet.cy + sheet.h / 2, bottom = sheet.cy - sheet.h / 2
    let paper = sheetPath(sheet), flap = flapPath(sheet)
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -26 * s), blur: 60 * s, color: color(0x000000, 0.40))
        ctx.addPath(paper); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
        ctx.restoreGState()
    }
    vertical(ctx, paper, color(0xFFFFFF), color(0xE9F0F3), top, bottom)
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: -10 * s, height: -12 * s), blur: 22 * s, color: color(navy, 0.30))
        ctx.addPath(flap); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
        ctx.restoreGState()
    }
    vertical(ctx, flap, color(0xFFC25A), color(amber), top, top - sheet.fold)

    // The face: two eyes and a small smile, in navy.
    ctx.setFillColor(color(navy)); ctx.setStrokeColor(color(navy)); ctx.setLineCap(.round)
    if tiny {
        // Hand-placed pixels: eyes at columns 6 and 9 (rows 8–9), smile = a U across rows 5–6.
        let pixels: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(6, 8, 1, 2), (9, 8, 1, 2), (7, 5, 2, 1), (6, 6, 1, 1), (9, 6, 1, 1)]
        for (x, y, w, h) in pixels { ctx.fill(CGRect(x: x * u, y: y * u, width: w * u, height: h * u)) }
    } else if small {
        // Eyes 2×4 px at columns 12–13 and 18–19 (rows 16–19); the smile arc's bottom lands on whole pixels.
        for x in [12, 18] as [CGFloat] { ctx.fill(CGRect(x: x * u, y: 16 * u, width: 2 * u, height: 4 * u)) }
        ctx.addArc(center: CGPoint(x: 16 * u, y: 15 * u), radius: 3 * u,
                   startAngle: 210 * .pi / 180, endAngle: 330 * .pi / 180, clockwise: false)
        ctx.setLineWidth(2 * u); ctx.strokePath()
    } else {
        let eyeW: CGFloat = 54, eyeH: CGFloat = 76, eyeDX: CGFloat = 84, eyeY = sheet.cy + 30
        for dx in [-eyeDX, eyeDX] {
            ctx.fillEllipse(in: CGRect(x: sheet.cx + dx - eyeW / 2, y: eyeY - eyeH / 2, width: eyeW, height: eyeH))
        }
        ctx.setFillColor(color(0xFFFFFF, 0.9))   // catchlights
        for dx in [-eyeDX, eyeDX] { ctx.fillEllipse(in: CGRect(x: sheet.cx + dx + 2, y: eyeY + 10, width: 16, height: 16)) }
        ctx.addArc(center: CGPoint(x: sheet.cx, y: sheet.cy - 34 + 92 * 0.2), radius: 92,
                   startAngle: 215 * .pi / 180, endAngle: 325 * .pi / 180, clockwise: false)
        ctx.setLineWidth(26); ctx.strokePath()
    }
    return rep
}

func write(_ px: Int, to path: String) {
    guard let png = render(px).representation(using: .png, properties: [:]),
          (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
        FileHandle.standardError.write("makeicon: could not write \(path)\n".data(using: .utf8)!); exit(1)
    }
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "jack.iconset"
if out.hasSuffix(".png") {
    write(1024, to: out)
} else {
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    for pt in [16, 32, 128, 256, 512] {
        write(pt, to: "\(out)/icon_\(pt)x\(pt).png")
        write(pt * 2, to: "\(out)/icon_\(pt)x\(pt)@2x.png")
    }
}
