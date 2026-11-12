// make_corpus.swift — builds Jack's public test corpus for Save as Word / searchable PDF.
//
//   swift harness/make_corpus.swift harness/corpus
//
// Every document is synthetic (made-up names and places). For each document it writes:
//   <id>.pdf        the text PDF, drawn with Core Text (fonts embedded)
//   <id>.scan.pdf   the same pages as a 200 DPI grey JPEG scan with skew and noise, no text layer
//   <id>.rough.pdf  (some documents) a worse scan: 150 DPI, more skew, more noise, lower quality
// and one manifest.json holding the ground truth: the body words in reading order (letterhead and
// page-number footer words kept apart, because Word puts those in the header and footer) and what
// the converter should do (refuse or not, pages, checkboxes, signatures, letterhead, page numbers).
// Noise is seeded, so a rerun draws the same pages.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "harness/corpus")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }
let serif = "Times-Roman", serifBold = "Times-Bold", sans = "Helvetica", sansBold = "Helvetica-Bold"

// MARK: - Page writer

struct Expect: Codable {
    var refuse = false
    var refuseKind: String? = nil       // "table" | "columns"
    var pages = 0
    var checkboxes = 0
    var checked = 0
    var signatures = 0
    var letterhead = false
    var pageNumbers = false
}

final class Writer {
    let W: CGFloat = 612, H: CGFloat = 792
    let left: CGFloat = 72, right: CGFloat = 540
    var ctx: CGContext
    var y: CGFloat = 0
    var page = 0
    var body: [String] = []
    var letterheadWords: [String] = []
    var footerWords: [String] = []
    var expect = Expect()
    var letterhead: [(String, String, CGFloat)] = []     // text, font, size — repeated on every page
    var footerTotal: Int? = nil                          // draws "Page N of M" when set

    init(url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    }

    func width(_ s: String, _ f: CTFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.init(kCTFontAttributeName as String): f]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    func draw(_ s: String, _ f: CTFont, x: CGFloat, y: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.init(kCTFontAttributeName as String): f]))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }

    func words(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " }).map(String.init) }

    func beginPage() {
        ctx.beginPDFPage(nil)
        page += 1
        y = H - 64
        if !letterhead.isEmpty {
            for (i, (t, f, s)) in letterhead.enumerated() {
                draw(t, font(f, s), x: left, y: y)
                if page == 1 { letterheadWords += words(t) }
                y -= i == 0 ? s + 6 : s + 4
            }
            ctx.setLineWidth(0.8)
            ctx.move(to: CGPoint(x: left, y: y + 2)); ctx.addLine(to: CGPoint(x: right, y: y + 2)); ctx.strokePath()
            y -= 30
            expect.letterhead = true
        }
    }

    func endPage() {
        if let total = footerTotal {
            let t = "Page \(page) of \(total)"
            let f = font(sans, 8.5)
            draw(t, f, x: (W - width(t, f)) / 2, y: 40)
            footerWords += words(t)
            expect.pageNumbers = true
        }
        ctx.endPDFPage()
    }

    func newPage() { endPage(); beginPage() }

    func room(_ h: CGFloat) { if y - h < 80 { newPage() } }

    /// Wrapped paragraph. `label` hangs in the left margin of the indent (numbered items).
    func para(_ text: String, _ fname: String = serif, size: CGFloat = 11, indent: CGFloat = 0,
              label: String? = nil, labelWidth: CGFloat = 18, lead: CGFloat? = nil, after: CGFloat = 8, center: Bool = false) {
        let f = font(fname, size)
        let lineH = lead ?? size * 1.36
        let x0 = left + indent + (label == nil ? 0 : labelWidth)
        let maxW = right - x0
        var lines: [String] = []
        var cur = ""
        for w in words(text) {
            let cand = cur.isEmpty ? w : cur + " " + w
            if width(cand, f) > maxW, !cur.isEmpty { lines.append(cur); cur = w } else { cur = cand }
        }
        if !cur.isEmpty { lines.append(cur) }
        for (i, l) in lines.enumerated() {
            room(lineH)
            if i == 0, let label {
                draw(label, f, x: left + indent, y: y)
                body += words(label)
            }
            let x = center ? (W - width(l, f)) / 2 : x0
            draw(l, f, x: x, y: y)
            body += words(l)
            y -= lineH
        }
        y -= after
    }

    func heading(_ text: String, underline: Bool = false, size: CGFloat = 11.5) {
        room(40)
        let f = font(serifBold, size)
        draw(text, f, x: left, y: y)
        body += words(text)
        if underline {
            ctx.setLineWidth(0.7)
            ctx.move(to: CGPoint(x: left, y: y - 2.5)); ctx.addLine(to: CGPoint(x: left + width(text, f), y: y - 2.5)); ctx.strokePath()
        }
        y -= size * 1.6
    }

    func title(_ text: String, size: CGFloat = 15) {
        let f = font(serifBold, size)
        draw(text, f, x: (W - width(text, f)) / 2, y: y)
        body += words(text)
        y -= size * 2
    }

    func checkbox(_ on: Bool, _ text: String) {
        room(18)
        let r = CGRect(x: left + 4, y: y - 1.5, width: 9.5, height: 9.5)
        ctx.setLineWidth(0.9)
        ctx.stroke(r)
        if on {
            ctx.setLineWidth(1.4)
            ctx.move(to: CGPoint(x: r.minX + 2, y: r.midY)); ctx.addLine(to: CGPoint(x: r.minX + 4, y: r.minY + 1.8))
            ctx.addLine(to: CGPoint(x: r.maxX - 1.5, y: r.maxY - 1.5)); ctx.strokePath()
            expect.checked += 1
        }
        expect.checkboxes += 1
        draw(text, font(serif, 11), x: left + 22, y: y)
        body += words(text)
        y -= 18
    }

    /// "Label: ________" fill-in line.
    func fill(_ label: String) {
        room(24)
        let f = font(serif, 11)
        draw(label, f, x: left, y: y)
        body += words(label)
        let x = left + width(label, f) + 6
        ctx.setLineWidth(0.7)
        ctx.move(to: CGPoint(x: x, y: y - 2)); ctx.addLine(to: CGPoint(x: right - 40, y: y - 2)); ctx.strokePath()
        y -= 24
    }

    /// A handwritten-looking scribble on a rule, with a printed label under it.
    func signature(_ label: String, seed: Int) {
        room(70)
        let base = y - 30
        ctx.setLineWidth(0.8)
        ctx.move(to: CGPoint(x: left, y: base)); ctx.addLine(to: CGPoint(x: left + 220, y: base)); ctx.strokePath()
        ctx.setLineWidth(1.3)
        var x = left + 12 + CGFloat(seed % 7) * 3
        ctx.move(to: CGPoint(x: x, y: base + 6))
        for i in 0..<9 {
            let up = i % 2 == 0
            let nx = x + 16 + CGFloat((seed * (i + 3)) % 9)
            ctx.addCurve(to: CGPoint(x: nx, y: base + (up ? 4 : 10)),
                         control1: CGPoint(x: x + 4, y: base + (up ? 26 : -4)),
                         control2: CGPoint(x: nx - 4, y: base + (up ? -6 : 24)))
            x = nx
        }
        ctx.strokePath()
        draw(label, font(serif, 10), x: left, y: base - 14)
        body += words(label)
        expect.signatures += 1
        y = base - 40
    }

    /// A ruled table; cells read row by row.
    func table(_ rows: [[String]], widths: [CGFloat]) {
        let f = font(sans, 9.5), fb = font(sansBold, 9.5)
        let rowH: CGFloat = 19
        ctx.setLineWidth(0.6)
        for (ri, row) in rows.enumerated() {
            room(rowH)
            var x = left
            for (ci, cell) in row.enumerated() {
                ctx.stroke(CGRect(x: x, y: y - 6, width: widths[ci], height: rowH))
                let isNum = cell.first.map { $0 == "$" || $0.isNumber } ?? false
                let fw = ri == 0 ? fb : f
                let tx = isNum && ri > 0 ? x + widths[ci] - 5 - width(cell, fw) : x + 5
                draw(cell, fw, x: tx, y: y)
                body += words(cell)
                x += widths[ci]
            }
            y -= rowH
        }
        y -= 14
    }

    /// Two text columns side by side; reading order is the whole left column, then the right.
    func columns(_ leftText: String, _ rightText: String) {
        let f = font(serif, 10.5)
        let gap: CGFloat = 24, colW = (right - left - gap) / 2
        func wrap(_ s: String) -> [String] {
            var lines: [String] = [], cur = ""
            for w in words(s) {
                let c = cur.isEmpty ? w : cur + " " + w
                if width(c, f) > colW, !cur.isEmpty { lines.append(cur); cur = w } else { cur = c }
            }
            if !cur.isEmpty { lines.append(cur) }
            return lines
        }
        let a = wrap(leftText), b = wrap(rightText)
        let top = y
        for (i, l) in a.enumerated() { draw(l, f, x: left, y: top - CGFloat(i) * 14); body += words(l) }
        for (i, l) in b.enumerated() { draw(l, f, x: left + colW + gap, y: top - CGFloat(i) * 14); body += words(l) }
        y = top - CGFloat(max(a.count, b.count)) * 14 - 12
    }

    func finish() -> Expect {
        endPage()
        ctx.closePDF()
        expect.pages = page
        return expect
    }
}

// MARK: - Scans

struct Rng {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
}

/// Draws every page of `src` as a grey bitmap, skewed by `degrees` and noised, JPEG-encodes it and
/// writes an image-only PDF of the same page size.
func scan(_ src: URL, to dst: URL, dpi: CGFloat, degrees: CGFloat, noise: Double, quality: Double, seed: UInt64) {
    let doc = CGPDFDocument(src as CFURL)!
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let out = CGContext(dst as CFURL, mediaBox: &box, nil)!
    var rng = Rng(s: seed)
    for p in 1...doc.numberOfPages {
        let page = doc.page(at: p)!
        let mb = page.getBoxRect(.mediaBox)
        let s = dpi / 72, w = Int(mb.width * s), h = Int(mb.height * s)
        let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        g.setFillColor(gray: 1, alpha: 1)
        g.fill(CGRect(x: 0, y: 0, width: w, height: h))
        g.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        g.rotate(by: degrees * .pi / 180)
        g.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
        g.scaleBy(x: s, y: s)
        g.drawPDFPage(page)
        let px = g.data!.bindMemory(to: UInt8.self, capacity: w * h)
        for i in 0..<(w * h) {
            var v = Double(px[i]) + (rng.next() + rng.next() - 1) * noise
            if rng.next() < 0.0004 { v = 60 }
            px[i] = UInt8(max(0, min(255, v.rounded())))
        }
        let img = g.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let jpeg = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data, nil)!, 0, nil)!
        out.beginPDFPage(nil)
        out.draw(jpeg, in: mb)
        out.endPDFPage()
    }
    out.closePDF()
}

// MARK: - Documents (all content made up)

struct Doc {
    let id: String
    let about: String
    let rough: Bool
    let skew: CGFloat
    let build: (Writer) -> Void
}

let docs: [Doc] = [
    Doc(id: "letter-plain", about: "one-page business letter", rough: true, skew: 0.4) { w in
        w.beginPage()
        w.para("Harbor Lane Property Services", sansBold, size: 15, after: 4)
        w.para("1200 Example Avenue, Suite 400, Springfield", sans, size: 9, after: 22)
        w.para("November 11, 2026", after: 12)
        w.para("Re: Service Agreement No. SA-2026-0417", serifBold, after: 12)
        w.para("Dear Ms. Alvarez,", after: 10)
        w.para("Thank you for renewing the maintenance agreement for the building at 85 Orchard Street. This letter confirms the terms we discussed on October 28 and the monthly fee of $1,250.00, payable on the first business day of each month beginning December 1.")
        w.para("Either party may end the agreement with 30 days written notice. Work requested outside this scope will be quoted separately and will not begin without your written approval. Invoices are due within 15 days of receipt.")
        w.para("Please sign and return the enclosed copy by November 25, 2026. If you have any questions, call our office at 555-0142 and ask for the service coordinator.", after: 18)
        w.para("Sincerely,", after: 30)
        w.para("Jordan Whitfield", after: 0)
        w.para("Operations Manager")
    },
    Doc(id: "letterhead-3page", about: "three pages with a repeated letterhead and Page N of M footer", rough: false, skew: -0.6) { w in
        w.letterhead = [("Brightwater Community Trust", sansBold, 14), ("400 Meridian Road, Lakeview  |  555-0199  |  office@brightwater.example", sans, 8.5)]
        w.footerTotal = 3
        w.beginPage()
        w.para("October 30, 2026", after: 12)
        w.para("Annual Statement to Beneficiaries", serifBold, size: 12.5, after: 12)
        let paras = [
            "This statement summarizes the activity of the trust for the year ending September 30, 2026. It is sent to every current beneficiary and to the co-trustees named in the trust instrument. Please keep it with your records.",
            "During the year the trust received rental income from two residential properties and interest from a money market account. Distributions were made quarterly in accordance with the schedule approved at the last annual meeting.",
            "The trustees met four times during the year. Minutes of each meeting are available on request. No amendments to the trust instrument were adopted, and no new beneficiaries were added.",
            "Property taxes for both residential properties were paid in full before the due date. The roof of the property on Linden Street was replaced in June after an inspection found water damage in the attic.",
            "Insurance coverage was reviewed in August. The trustees increased the liability limit on both properties after comparing quotes from three carriers. The new premium is reflected in the expenses for the fourth quarter.",
        ]
        for p in paras { w.para(p) }
        w.newPage()
        w.para("Questions Raised at the Annual Meeting", serifBold, size: 12, after: 10)
        for p in paras.reversed() { w.para(p) }
        w.newPage()
        w.para("Next Steps", serifBold, size: 12, after: 10)
        w.para("The trustees will mail the next quarterly distribution on January 15, 2027. Beneficiaries who have changed their mailing address or bank details should write to the trust office before December 31 so the change can be verified in time.")
        w.para("A copy of the full accounting, prepared by the trust's outside accountant, will be available at the office after February 1. Beneficiaries may request a copy by mail or pick one up in person during office hours.", after: 18)
        w.para("For the Trustees,", after: 30)
        w.para("Morgan Ellery", after: 0)
        w.para("Co-Trustee")
    },
    Doc(id: "numbered-terms", about: "numbered and lettered terms with hanging indents", rough: false, skew: 0.8) { w in
        w.beginPage()
        w.title("TERMS OF ENGAGEMENT")
        let items = [
            ("1.", "Scope. The consultant will review the client's office network and prepare a written report of findings and recommendations."),
            ("2.", "Schedule. Work will begin within ten business days of signing and will be completed within thirty days, unless both parties agree otherwise in writing."),
            ("3.", "Fees. The client will pay the fixed fee stated in the proposal. Travel outside the county is billed at cost."),
            ("4.", "Access. The client will provide:"),
        ]
        for (l, t) in items { w.para(t, label: l, labelWidth: 22) }
        for (l, t) in [("(a)", "a contact person who can answer questions during business hours;"),
                       ("(b)", "administrator access to the systems listed in the proposal; and"),
                       ("(c)", "a quiet work space when the consultant is on site.")] {
            w.para(t, indent: 22, label: l, labelWidth: 26, after: 4)
        }
        w.y -= 6
        for (l, t) in [("5.", "Confidentiality. Each party will keep the other's confidential information private and will use it only to perform this engagement."),
                       ("6.", "Termination. Either party may end this engagement with fourteen days written notice. The client will pay for work completed up to the date of termination."),
                       ("7.", "Entire agreement. These terms and the proposal are the whole agreement between the parties and replace any earlier discussions.")] {
            w.para(t, label: l, labelWidth: 22)
        }
    },
    Doc(id: "intake-form", about: "form with fill-in lines, checkboxes and a signature", rough: true, skew: -0.3) { w in
        w.beginPage()
        w.title("New Client Intake Form", size: 14)
        w.para("Please complete every line in ink. Use one form for each household. Return it to the front desk or mail it to the address on the back.", after: 14)
        w.fill("Full name:")
        w.fill("Mailing address:")
        w.fill("Phone number:")
        w.fill("Date of birth:")
        w.y -= 6
        w.para("How did you hear about us? Check all that apply.", serifBold, after: 8)
        w.checkbox(true, "A friend or family member")
        w.checkbox(false, "An online search")
        w.checkbox(false, "A newspaper or radio advertisement")
        w.checkbox(true, "Another office referred me")
        w.y -= 8
        w.para("Preferred way to contact you:", serifBold, after: 8)
        w.checkbox(false, "Phone call")
        w.checkbox(true, "Email")
        w.y -= 10
        w.para("By signing below I confirm that the information on this form is true and complete to the best of my knowledge.", after: 8)
        w.signature("Signature of Applicant", seed: 5)
        w.fill("Date signed:")
    },
    Doc(id: "contract-2page", about: "two-page agreement, centered title, underlined headings, two signatures", rough: true, skew: 0.5) { w in
        w.beginPage()
        w.title("EQUIPMENT RENTAL AGREEMENT")
        w.para("This agreement is made on November 3, 2026 between Northfield Tool Rental (the Owner) and Riverside Builders (the Renter).", after: 12)
        let sections = [
            ("Rental Period", "The rental begins when the equipment leaves the Owner's yard and ends when it is returned and checked in. A day is counted for any part of a calendar day."),
            ("Rates and Deposit", "The Renter will pay the daily rate shown on the rental ticket. A refundable deposit of $500.00 is due before the equipment leaves the yard and will be returned within seven days of check-in, less any charges for damage or cleaning."),
            ("Care of Equipment", "The Renter will use the equipment only for its intended purpose, will not lend it to anyone else, and will keep it secure when it is not in use. Fuel and routine fluids are the Renter's responsibility."),
            ("Damage and Loss", "The Renter is responsible for damage beyond normal wear and for loss or theft while the equipment is in the Renter's care. Repairs will be billed at the Owner's standard shop rate."),
            ("Insurance", "The Renter will carry general liability insurance of at least $1,000,000 per occurrence and will name the Owner as an additional insured during the rental period."),
            ("Late Return", "Equipment returned after the agreed date is charged at the daily rate for each extra day. If equipment is more than five days late the Owner may recover it at the Renter's expense."),
        ]
        for (h, t) in sections { w.heading(h, underline: true); w.para(t) }
        w.newPage()
        for (h, t) in sections.prefix(3) { w.heading(h + " (continued)", underline: true); w.para(t) }
        w.para("Signed by the parties on the date written above.", after: 12)
        w.signature("Signature of Owner", seed: 3)
        w.signature("Signature of Renter", seed: 8)
    },
    Doc(id: "fine-print", about: "dense small type", rough: false, skew: -0.9) { w in
        w.beginPage()
        w.para("Notice of Privacy Practices", serifBold, size: 12, after: 10)
        let t = "This notice describes how information about you may be used and disclosed and how you can get access to this information. Please review it carefully. We are required to keep your information private, to give you this notice of our legal duties and privacy practices, and to follow the terms of the notice currently in effect. We may change our practices and the terms of this notice at any time, and the new notice will apply to all information we keep. You may ask us to limit how we use or share your information, to send communications to another address, or to give you a copy of your records. We will respond to written requests within thirty days. If you believe your privacy rights have been violated you may file a complaint with our office. We will not retaliate against you for filing a complaint."
        for _ in 0..<4 { w.para(t, size: 8.5, after: 6) }
    },
    Doc(id: "memo", about: "memo header block and bulleted list", rough: false, skew: 0.3) { w in
        w.beginPage()
        w.para("MEMORANDUM", sansBold, size: 16, after: 14)
        for (k, v) in [("TO:", "All office staff"), ("FROM:", "Facilities"), ("DATE:", "November 9, 2026"), ("RE:", "Parking lot resurfacing")] {
            w.para(v, label: k, labelWidth: 60, after: 4)
        }
        w.y -= 10
        w.para("The parking lot will be resurfaced over the weekend of November 21. The work requires the lot to be completely empty, so please plan ahead.", after: 10)
        for t in ["Move every vehicle out of the lot by 6:00 PM on Friday, November 20.",
                  "Do not return before 7:00 AM on Monday, November 23.",
                  "Street parking on Cedar Avenue is free on weekends.",
                  "Visitors with an appointment that weekend should be told to use the garage on Fifth Street."] {
            w.para(t, indent: 8, label: "\u{2022}", labelWidth: 16, after: 5)
        }
        w.y -= 8
        w.para("Thank you for your patience while the work is done.")
    },
    Doc(id: "price-table", about: "price sheet laid out as a ruled table (should be refused)", rough: false, skew: 0.2) { w in
        w.beginPage()
        w.para("Price Sheet, Fourth Quarter 2026", serifBold, size: 13, after: 12)
        var rows = [["Item", "Description", "Unit", "Price"]]
        let names = ["Gravel", "Sand", "Topsoil", "Mulch", "Pavers", "Edging", "Fabric", "Stakes", "Gravel fine", "Boulders", "Rebar", "Mesh", "Lumber", "Plywood"]
        for (i, n) in names.enumerated() {
            rows.append(["\(100 + i)", n, i % 2 == 0 ? "ton" : "each", String(format: "$%.2f", Double(18 + i * 7) + 0.5)])
        }
        w.table(rows, widths: [60, 220, 80, 100])
    },
    Doc(id: "newsletter-columns", about: "two-column newsletter page (should be refused)", rough: false, skew: -0.4) { w in
        w.beginPage()
        w.para("Neighborhood News, Winter Edition", serifBold, size: 15, after: 14)
        let a = "The community garden finished its best season yet. Volunteers harvested more than four hundred pounds of vegetables, and most of it went to the food pantry on Second Street. Plots for next year open for sign-up in February. The garden committee is looking for two new members who can help plan the spring planting and organize the tool shed."
        let b = "The library will extend its hours on Thursdays starting in January. Evening hours will run until eight o'clock, and the reading room will host a homework club for students in grades four through eight. Parents are welcome to stay. The library also needs volunteers to shelve returned books on weekend mornings."
        w.columns(a + " " + a, b + " " + b)
    },
]

// MARK: - Build

struct Variant: Codable { let file: String; let kind: String }
struct Entry: Codable {
    let id: String
    let about: String
    let expect: Expect
    let bodyWords: [String]
    let letterheadWords: [String]
    let footerWords: [String]
    let variants: [Variant]
}

var entries: [Entry] = []
for (i, d) in docs.enumerated() {
    let pdf = outDir.appendingPathComponent("\(d.id).pdf")
    let w = Writer(url: pdf)
    d.build(w)
    var expect = w.finish()
    if d.id == "price-table" { expect.refuse = true; expect.refuseKind = "table" }
    if d.id == "newsletter-columns" { expect.refuse = true; expect.refuseKind = "columns" }
    var variants = [Variant(file: pdf.lastPathComponent, kind: "text")]
    let scanURL = outDir.appendingPathComponent("\(d.id).scan.pdf")
    scan(pdf, to: scanURL, dpi: 200, degrees: d.skew, noise: 9, quality: 0.6, seed: UInt64(1000 + i))
    variants.append(Variant(file: scanURL.lastPathComponent, kind: "scan"))
    if d.rough {
        let roughURL = outDir.appendingPathComponent("\(d.id).rough.pdf")
        scan(pdf, to: roughURL, dpi: 150, degrees: d.skew * 2.5, noise: 18, quality: 0.45, seed: UInt64(2000 + i))
        variants.append(Variant(file: roughURL.lastPathComponent, kind: "rough"))
    }
    entries.append(Entry(id: d.id, about: d.about, expect: expect, bodyWords: w.body,
                         letterheadWords: w.letterheadWords, footerWords: w.footerWords, variants: variants))
    print("\(d.id): \(expect.pages) page(s), \(w.body.count) body words, \(variants.count) files")
}

let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
let docsJSON = String(data: try! enc.encode(entries), encoding: .utf8)!
let json = "{\n  \"version\": 1,\n  \"generator\": \"harness/make_corpus.swift\",\n  \"documents\": " + docsJSON + "\n}\n"
try! json.write(to: outDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
print("wrote \(entries.count) documents to \(outDir.path)")
