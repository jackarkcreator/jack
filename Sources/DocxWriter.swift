// DocxWriter — writes a Word (.docx / Office Open XML) package with no third-party code:
// the XML parts are generated here and zipped by a small built-in ZIP writer (raw DEFLATE
// via Apple's Compression framework, CRC-32 computed locally).
//
// Scope is what Save as Word needs: paragraphs with indents, hanging lists, tab stops,
// alignment and spacing; runs with bold / italic / underline / highlight / size / font;
// Word checkboxes (w14 content controls); a header image (letterhead) and a
// "N of M" footer; page breaks. Units: everything in this file takes POINTS.
import AppKit
import Compression

struct DocxRunStyle {
    var bold = false
    var italic = false
    var underline = false
    var highlight = false
    var size: CGFloat? = nil
    var font: String? = nil
    var color: String? = nil      // "RRGGBB"
}

enum DocxRun {
    case text(String, DocxRunStyle)
    case tab(DocxRunStyle)
    case checkbox(Bool)
    case blank(CGFloat, DocxRunStyle)  // an underlined fill-in line of this width (points)
}

struct DocxParagraph {
    enum Align: String { case left, center, right, both }
    var runs: [DocxRun] = []
    var align: Align = .left
    var leftIndent: CGFloat = 0
    var firstLine: CGFloat = 0          // negative = hanging indent
    var spaceBefore: CGFloat = 0
    var spaceAfter: CGFloat = 0
    var pageBreakBefore = false
    var keepWithNext = false
    var tabStops: [CGFloat] = []        // left tab stops, measured from the left margin
}

struct DocxModel {
    var title = ""
    var pageWidth: CGFloat = 612
    var pageHeight: CGFloat = 792
    var marginTop: CGFloat = 72
    var marginBottom: CGFloat = 72
    var marginLeft: CGFloat = 72
    var marginRight: CGFloat = 72
    var headerDistance: CGFloat = 36
    var footerDistance: CGFloat = 30
    var baseFont = "Times New Roman"
    var baseSize: CGFloat = 11
    var headerPNG: Data? = nil
    var headerSize: CGSize = .zero      // points
    var headerOffsetX: CGFloat = 0      // relative to the left margin (negative = into the margin)
    var pageNumberFooter = false
    var paragraphs: [DocxParagraph] = []
}

enum DocxWriter {

    static func write(_ model: DocxModel, to url: URL) throws {
        var parts: [(String, Data)] = []
        let hasHeader = model.headerPNG != nil
        parts.append(("[Content_Types].xml", Data(contentTypes(header: hasHeader, footer: model.pageNumberFooter).utf8)))
        parts.append(("_rels/.rels", Data(rootRels.utf8)))
        parts.append(("docProps/core.xml", Data(core(model.title).utf8)))
        parts.append(("docProps/app.xml", Data(app.utf8)))
        parts.append(("word/document.xml", Data(document(model).utf8)))
        parts.append(("word/styles.xml", Data(styles(model).utf8)))
        parts.append(("word/settings.xml", Data(settings.utf8)))
        parts.append(("word/_rels/document.xml.rels", Data(documentRels(header: hasHeader, footer: model.pageNumberFooter).utf8)))
        if let png = model.headerPNG {
            parts.append(("word/header1.xml", Data(header(model).utf8)))
            parts.append(("word/_rels/header1.xml.rels", Data(headerRels.utf8)))
            parts.append(("word/media/letterhead.png", png))
        }
        if model.pageNumberFooter {
            parts.append(("word/footer1.xml", Data(footer.utf8)))
        }
        let zip = ZipWriter.archive(parts)
        try zip.write(to: url, options: .atomic)
    }

    // MARK: - Units and escaping

    static func tw(_ pt: CGFloat) -> Int { Int((pt * 20).rounded()) }          // twentieths of a point
    static func hp(_ pt: CGFloat) -> Int { Int((pt * 2).rounded()) }           // half-points
    static func emu(_ pt: CGFloat) -> Int { Int((pt * 12700).rounded()) }

    static func esc(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            default:
                // XML 1.0 forbids most C0 controls.
                if u.value < 0x20 && u != "\t" && u != "\n" && u != "\r" { continue }
                o.unicodeScalars.append(u)
            }
        }
        return o
    }

    static let ns = """
    xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas" \
    xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" \
    xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
    xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" \
    mc:Ignorable="w14"
    """

    // MARK: - document.xml

    static func document(_ m: DocxModel) -> String {
        var b = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document \(ns)><w:body>"
        for p in m.paragraphs { b += paragraph(p) }
        b += "<w:sectPr>"
        if m.headerPNG != nil { b += "<w:headerReference w:type=\"default\" r:id=\"rIdHeader\"/>" }
        if m.pageNumberFooter { b += "<w:footerReference w:type=\"default\" r:id=\"rIdFooter\"/>" }
        b += "<w:pgSz w:w=\"\(tw(m.pageWidth))\" w:h=\"\(tw(m.pageHeight))\"/>"
        b += "<w:pgMar w:top=\"\(tw(m.marginTop))\" w:right=\"\(tw(m.marginRight))\" w:bottom=\"\(tw(m.marginBottom))\" w:left=\"\(tw(m.marginLeft))\" w:header=\"\(tw(m.headerDistance))\" w:footer=\"\(tw(m.footerDistance))\" w:gutter=\"0\"/>"
        b += "</w:sectPr></w:body></w:document>"
        return b
    }

    static func paragraph(_ p: DocxParagraph) -> String {
        var b = "<w:p><w:pPr>"
        if p.keepWithNext { b += "<w:keepNext/>" }
        if p.pageBreakBefore { b += "<w:pageBreakBefore/>" }
        if !p.tabStops.isEmpty {
            b += "<w:tabs>"
            for t in p.tabStops.sorted() where t > 0 { b += "<w:tab w:val=\"left\" w:pos=\"\(tw(t))\"/>" }
            b += "</w:tabs>"
        }
        b += "<w:spacing w:before=\"\(tw(p.spaceBefore))\" w:after=\"\(tw(p.spaceAfter))\"/>"
        if p.leftIndent != 0 || p.firstLine != 0 {
            b += "<w:ind w:left=\"\(tw(p.leftIndent))\""
            if p.firstLine < 0 { b += " w:hanging=\"\(tw(-p.firstLine))\"" }
            else if p.firstLine > 0 { b += " w:firstLine=\"\(tw(p.firstLine))\"" }
            b += "/>"
        }
        if p.align != .left { b += "<w:jc w:val=\"\(p.align.rawValue)\"/>" }
        b += "</w:pPr>"
        for r in p.runs { b += run(r) }
        b += "</w:p>"
        return b
    }

    static func rPr(_ s: DocxRunStyle) -> String {
        var b = ""
        if let f = s.font { b += "<w:rFonts w:ascii=\"\(esc(f))\" w:hAnsi=\"\(esc(f))\" w:cs=\"\(esc(f))\"/>" }
        if s.bold { b += "<w:b/><w:bCs/>" }
        if s.italic { b += "<w:i/><w:iCs/>" }
        if let c = s.color { b += "<w:color w:val=\"\(c)\"/>" }
        if let z = s.size { b += "<w:sz w:val=\"\(hp(z))\"/><w:szCs w:val=\"\(hp(z))\"/>" }
        if s.highlight { b += "<w:highlight w:val=\"yellow\"/>" }
        if s.underline { b += "<w:u w:val=\"single\"/>" }
        return b.isEmpty ? "" : "<w:rPr>\(b)</w:rPr>"
    }

    static func run(_ r: DocxRun) -> String {
        switch r {
        case .text(let t, let s):
            return "<w:r>\(rPr(s))<w:t xml:space=\"preserve\">\(esc(t))</w:t></w:r>"
        case .tab(let s):
            return "<w:r>\(rPr(s))<w:tab/></w:r>"
        case .blank(let width, var s):
            s.underline = true
            // A no-break space is ~0.25 em wide in the common text faces.
            let em = (s.size ?? 11) * 0.25
            let n = max(2, Int((width / em).rounded()))
            return "<w:r>\(rPr(s))<w:t xml:space=\"preserve\">\(String(repeating: "\u{00A0}", count: n))</w:t></w:r>"
        case .checkbox(let on):
            let glyph = on ? "\u{2612}" : "\u{2610}"
            return "<w:sdt><w:sdtPr><w14:checkbox><w14:checked w14:val=\"\(on ? 1 : 0)\"/>"
                + "<w14:checkedState w14:val=\"2612\" w14:font=\"MS Gothic\"/><w14:uncheckedState w14:val=\"2610\" w14:font=\"MS Gothic\"/>"
                + "</w14:checkbox></w:sdtPr><w:sdtContent><w:r><w:rPr><w:rFonts w:ascii=\"MS Gothic\" w:eastAsia=\"MS Gothic\" w:hAnsi=\"MS Gothic\"/></w:rPr>"
                + "<w:t>\(glyph)</w:t></w:r></w:sdtContent></w:sdt>"
        }
    }

    // MARK: - header / footer

    static func header(_ m: DocxModel) -> String {
        let cx = emu(m.headerSize.width), cy = emu(m.headerSize.height)
        var ind = ""
        if m.headerOffsetX != 0 { ind = "<w:ind w:left=\"\(tw(m.headerOffsetX))\"/>" }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:hdr \(ns)><w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/>\(ind)</w:pPr><w:r><w:drawing>"
            + "<wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:docPr id=\"1\" name=\"Letterhead\"/>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>"
            + "<pic:nvPicPr><pic:cNvPr id=\"0\" name=\"letterhead.png\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"rIdLogo\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p></w:hdr>"
    }

    static let footer: String = {
        func field(_ instr: String) -> String {
            let rp = "<w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\"/><w:sz w:val=\"16\"/></w:rPr>"
            return "<w:r>\(rp)<w:fldChar w:fldCharType=\"begin\"/></w:r><w:r>\(rp)<w:instrText xml:space=\"preserve\"> \(instr) </w:instrText></w:r>"
                + "<w:r>\(rp)<w:fldChar w:fldCharType=\"separate\"/></w:r><w:r>\(rp)<w:t>1</w:t></w:r><w:r>\(rp)<w:fldChar w:fldCharType=\"end\"/></w:r>"
        }
        let rp = "<w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\"/><w:sz w:val=\"16\"/></w:rPr>"
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:ftr \(ns)><w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr>"
            + field("PAGE") + "<w:r>\(rp)<w:t xml:space=\"preserve\"> of </w:t></w:r>" + field("NUMPAGES") + "</w:p></w:ftr>"
    }()

    // MARK: - package parts

    static func contentTypes(header: Bool, footer: Bool) -> String {
        var b = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Default Extension=\"png\" ContentType=\"image/png\"/>"
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
            + "<Override PartName=\"/word/settings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml\"/>"
            + "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
            + "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
        if header { b += "<Override PartName=\"/word/header1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml\"/>" }
        if footer { b += "<Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>" }
        return b + "</Types>"
    }

    static let rootRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
        + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
        + "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>"
        + "</Relationships>"

    static func documentRels(header: Bool, footer: Bool) -> String {
        var b = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            + "<Relationship Id=\"rIdSettings\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings\" Target=\"settings.xml\"/>"
        if header { b += "<Relationship Id=\"rIdHeader\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/>" }
        if footer { b += "<Relationship Id=\"rIdFooter\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>" }
        return b + "</Relationships>"
    }

    static let headerRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + "<Relationship Id=\"rIdLogo\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/letterhead.png\"/>"
        + "</Relationships>"

    static func styles(_ m: DocxModel) -> String {
        let f = esc(m.baseFont)
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:styles \(ns)>"
            + "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"\(f)\" w:eastAsia=\"\(f)\" w:hAnsi=\"\(f)\" w:cs=\"\(f)\"/>"
            + "<w:sz w:val=\"\(hp(m.baseSize))\"/><w:szCs w:val=\"\(hp(m.baseSize))\"/><w:lang w:val=\"en-US\"/></w:rPr></w:rPrDefault>"
            + "<w:pPrDefault><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
            + "</w:styles>"
    }

    static let settings = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:settings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        + "<w:defaultTabStop w:val=\"720\"/><w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>"

    static func core(_ title: String) -> String {
        let iso = ISO8601DateFormatter().string(from: Date())
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
            + "<dc:title>\(esc(title))</dc:title><dc:creator>Jack (ThinkOpen)</dc:creator>"
            + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(iso)</dcterms:created><dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(iso)</dcterms:modified>"
            + "</cp:coreProperties>"
    }

    static let app = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>Jack</Application></Properties>"
}

// MARK: - ZIP (PKWARE APPNOTE 6.3, no ZIP64 — a .docx is never near 4 GB)

enum ZipWriter {

    static func archive(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        let (dosTime, dosDate) = dosStamp(Date())
        for (name, raw) in entries {
            let nameData = Data(name.utf8)
            let crc = crc32(raw)
            var method: UInt16 = 8
            var body = deflate(raw)
            if body == nil || body!.count >= raw.count { method = 0; body = raw }
            let offset = UInt32(out.count)

            out.append(le32(0x04034b50)); out.append(le16(20)); out.append(le16(0x0800)) // UTF-8 names
            out.append(le16(method)); out.append(le16(dosTime)); out.append(le16(dosDate))
            out.append(le32(crc)); out.append(le32(UInt32(body!.count))); out.append(le32(UInt32(raw.count)))
            out.append(le16(UInt16(nameData.count))); out.append(le16(0))
            out.append(nameData); out.append(body!)

            central.append(le32(0x02014b50)); central.append(le16(20)); central.append(le16(20)); central.append(le16(0x0800))
            central.append(le16(method)); central.append(le16(dosTime)); central.append(le16(dosDate))
            central.append(le32(crc)); central.append(le32(UInt32(body!.count))); central.append(le32(UInt32(raw.count)))
            central.append(le16(UInt16(nameData.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0)); central.append(le32(offset))
            central.append(nameData)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(le32(0x06054b50)); out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(entries.count))); out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(central.count))); out.append(le32(cdOffset)); out.append(le16(0))
        return out
    }

    /// Raw DEFLATE (RFC 1951) — what ZIP method 8 stores. Apple's COMPRESSION_ZLIB is raw deflate.
    static func deflate(_ data: Data) -> Data? {
        if data.isEmpty { return Data() }
        let cap = data.count + data.count / 10 + 1024
        var dst = [UInt8](repeating: 0, count: cap)
        let n = data.withUnsafeBytes { src -> Int in
            compression_encode_buffer(&dst, cap, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 ? Data(dst[0..<n]) : nil
    }

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { buf in
            for b in buf { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFFFFFF
    }

    static func dosStamp(_ d: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | ((c.second ?? 0) / 2))
        let date = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, date)
    }

    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }
}
