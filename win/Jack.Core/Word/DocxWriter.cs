// DocxWriter — writes a Word (.docx / Office Open XML) package with no third-party code.
// Port of Sources/DocxWriter.swift: the same XML parts with the same markup; the ZIP container
// comes from System.IO.Compression instead of the Mac's own ZIP writer.
//
// Scope is what Save as Word needs: paragraphs with indents, hanging lists, tab stops,
// alignment and spacing; runs with bold / italic / underline / highlight / size / font;
// Word checkboxes (w14 content controls); a header image (letterhead) and a
// "N of M" footer; page breaks. Units: everything in this file takes POINTS.
using System.Globalization;
using System.IO.Compression;
using System.Text;

namespace Jack.Core.Word;

public record struct DocxRunStyle
{
    public bool Bold;
    public bool Italic;
    public bool Underline;
    public bool Highlight;
    public double? Size;
    public string? Font;
    public string? Color;      // "RRGGBB"
}

public enum DocxRunType { Text, Tab, Checkbox, Blank }

public sealed class DocxRun
{
    public DocxRunType Type { get; private init; }
    public string Text { get; private init; } = "";
    public DocxRunStyle Style { get; private init; }
    public bool Checked { get; private init; }
    public double Width { get; private init; }   // .Blank: an underlined fill-in line of this width (points)

    public static DocxRun TextRun(string text, DocxRunStyle style) => new() { Type = DocxRunType.Text, Text = text, Style = style };
    public static DocxRun Tab(DocxRunStyle style) => new() { Type = DocxRunType.Tab, Style = style };
    public static DocxRun Checkbox(bool on) => new() { Type = DocxRunType.Checkbox, Checked = on };
    public static DocxRun Blank(double width, DocxRunStyle style) => new() { Type = DocxRunType.Blank, Width = width, Style = style };
}

public enum DocxAlign { Left, Center, Right, Both }

public sealed class DocxParagraph
{
    public List<DocxRun> Runs = new();
    public DocxAlign Align = DocxAlign.Left;
    public double LeftIndent;
    public double FirstLine;            // negative = hanging indent
    public double SpaceBefore;
    public double SpaceAfter;
    public bool PageBreakBefore;
    public bool KeepWithNext;
    public List<double> TabStops = new();   // left tab stops, measured from the left margin
}

public sealed class DocxModel
{
    public string Title = "";
    public double PageWidth = 612;
    public double PageHeight = 792;
    public double MarginTop = 72;
    public double MarginBottom = 72;
    public double MarginLeft = 72;
    public double MarginRight = 72;
    public double HeaderDistance = 36;
    public double FooterDistance = 30;
    public string BaseFont = "Times New Roman";
    public double BaseSize = 11;
    public byte[]? HeaderPNG;
    public double HeaderWidth, HeaderHeight;   // points
    public double HeaderOffsetX;               // relative to the left margin (negative = into the margin)
    public bool PageNumberFooter;
    public List<DocxParagraph> Paragraphs = new();
}

public static class DocxWriter
{
    public static void Write(DocxModel model, string path)
    {
        var parts = new List<(string, byte[])>();
        bool hasHeader = model.HeaderPNG != null;
        var u = new UTF8Encoding(false);
        parts.Add(("[Content_Types].xml", u.GetBytes(ContentTypes(hasHeader, model.PageNumberFooter))));
        parts.Add(("_rels/.rels", u.GetBytes(RootRels)));
        parts.Add(("docProps/core.xml", u.GetBytes(Core(model.Title))));
        parts.Add(("docProps/app.xml", u.GetBytes(App)));
        parts.Add(("word/document.xml", u.GetBytes(Document(model))));
        parts.Add(("word/styles.xml", u.GetBytes(Styles(model))));
        parts.Add(("word/settings.xml", u.GetBytes(Settings)));
        parts.Add(("word/_rels/document.xml.rels", u.GetBytes(DocumentRels(hasHeader, model.PageNumberFooter))));
        if (model.HeaderPNG is byte[] png)
        {
            parts.Add(("word/header1.xml", u.GetBytes(Header(model))));
            parts.Add(("word/_rels/header1.xml.rels", u.GetBytes(HeaderRels)));
            parts.Add(("word/media/letterhead.png", png));
        }
        if (model.PageNumberFooter)
            parts.Add(("word/footer1.xml", u.GetBytes(Footer)));

        // Atomic, like Data.write(options: .atomic): build beside the target, then move over it.
        var dir = Path.GetDirectoryName(Path.GetFullPath(path)) ?? ".";
        var tmp = Path.Combine(dir, "." + Path.GetFileName(path) + "." + Guid.NewGuid().ToString("N")[..8] + ".tmp");
        try
        {
            using (var fs = File.Create(tmp))
            using (var zip = new ZipArchive(fs, ZipArchiveMode.Create))
            {
                foreach (var (name, data) in parts)
                {
                    var e = zip.CreateEntry(name, CompressionLevel.Optimal);
                    using var s = e.Open();
                    s.Write(data, 0, data.Length);
                }
            }
            File.Move(tmp, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(tmp)) File.Delete(tmp);
        }
    }

    // MARK: - Units and escaping

    public static int Tw(double pt) => (int)Math.Round(pt * 20, MidpointRounding.AwayFromZero);       // twentieths of a point
    public static int Hp(double pt) => (int)Math.Round(pt * 2, MidpointRounding.AwayFromZero);        // half-points
    public static int Emu(double pt) => (int)Math.Round(pt * 12700, MidpointRounding.AwayFromZero);

    static string I(int v) => v.ToString(CultureInfo.InvariantCulture);

    public static string Esc(string s)
    {
        var o = new StringBuilder(s.Length);
        foreach (var r in s.EnumerateRunes())
        {
            switch (r.Value)
            {
                case '&': o.Append("&amp;"); break;
                case '<': o.Append("&lt;"); break;
                case '>': o.Append("&gt;"); break;
                case '"': o.Append("&quot;"); break;
                default:
                    // XML 1.0 forbids most C0 controls.
                    if (r.Value < 0x20 && r.Value != '\t' && r.Value != '\n' && r.Value != '\r') continue;
                    o.Append(r.ToString());
                    break;
            }
        }
        return o.ToString();
    }

    const string Ns =
        "xmlns:wpc=\"http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas\" " +
        "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" " +
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" " +
        "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" " +
        "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" " +
        "xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\" " +
        "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" " +
        "xmlns:w14=\"http://schemas.microsoft.com/office/word/2010/wordml\" " +
        "mc:Ignorable=\"w14\"";

    const string XmlHead = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n";

    // MARK: - document.xml

    public static string Document(DocxModel m)
    {
        var b = new StringBuilder();
        b.Append(XmlHead).Append("<w:document ").Append(Ns).Append("><w:body>");
        foreach (var p in m.Paragraphs) b.Append(Paragraph(p));
        b.Append("<w:sectPr>");
        if (m.HeaderPNG != null) b.Append("<w:headerReference w:type=\"default\" r:id=\"rIdHeader\"/>");
        if (m.PageNumberFooter) b.Append("<w:footerReference w:type=\"default\" r:id=\"rIdFooter\"/>");
        b.Append($"<w:pgSz w:w=\"{I(Tw(m.PageWidth))}\" w:h=\"{I(Tw(m.PageHeight))}\"/>");
        b.Append($"<w:pgMar w:top=\"{I(Tw(m.MarginTop))}\" w:right=\"{I(Tw(m.MarginRight))}\" w:bottom=\"{I(Tw(m.MarginBottom))}\" w:left=\"{I(Tw(m.MarginLeft))}\" w:header=\"{I(Tw(m.HeaderDistance))}\" w:footer=\"{I(Tw(m.FooterDistance))}\" w:gutter=\"0\"/>");
        b.Append("</w:sectPr></w:body></w:document>");
        return b.ToString();
    }

    public static string Paragraph(DocxParagraph p)
    {
        var b = new StringBuilder("<w:p><w:pPr>");
        if (p.KeepWithNext) b.Append("<w:keepNext/>");
        if (p.PageBreakBefore) b.Append("<w:pageBreakBefore/>");
        if (p.TabStops.Count > 0)
        {
            b.Append("<w:tabs>");
            foreach (var t in SwiftSort.Sorted(p.TabStops)) if (t > 0) b.Append($"<w:tab w:val=\"left\" w:pos=\"{I(Tw(t))}\"/>");
            b.Append("</w:tabs>");
        }
        b.Append($"<w:spacing w:before=\"{I(Tw(p.SpaceBefore))}\" w:after=\"{I(Tw(p.SpaceAfter))}\"/>");
        if (p.LeftIndent != 0 || p.FirstLine != 0)
        {
            b.Append($"<w:ind w:left=\"{I(Tw(p.LeftIndent))}\"");
            if (p.FirstLine < 0) b.Append($" w:hanging=\"{I(Tw(-p.FirstLine))}\"");
            else if (p.FirstLine > 0) b.Append($" w:firstLine=\"{I(Tw(p.FirstLine))}\"");
            b.Append("/>");
        }
        if (p.Align != DocxAlign.Left) b.Append($"<w:jc w:val=\"{p.Align.ToString().ToLowerInvariant()}\"/>");
        b.Append("</w:pPr>");
        foreach (var r in p.Runs) b.Append(Run(r));
        b.Append("</w:p>");
        return b.ToString();
    }

    public static string RPr(DocxRunStyle s)
    {
        var b = new StringBuilder();
        if (s.Font is string f) b.Append($"<w:rFonts w:ascii=\"{Esc(f)}\" w:hAnsi=\"{Esc(f)}\" w:cs=\"{Esc(f)}\"/>");
        if (s.Bold) b.Append("<w:b/><w:bCs/>");
        if (s.Italic) b.Append("<w:i/><w:iCs/>");
        if (s.Color is string c) b.Append($"<w:color w:val=\"{c}\"/>");
        if (s.Size is double z) b.Append($"<w:sz w:val=\"{I(Hp(z))}\"/><w:szCs w:val=\"{I(Hp(z))}\"/>");
        if (s.Highlight) b.Append("<w:highlight w:val=\"yellow\"/>");
        if (s.Underline) b.Append("<w:u w:val=\"single\"/>");
        return b.Length == 0 ? "" : $"<w:rPr>{b}</w:rPr>";
    }

    public static string Run(DocxRun r)
    {
        switch (r.Type)
        {
            case DocxRunType.Text:
                return $"<w:r>{RPr(r.Style)}<w:t xml:space=\"preserve\">{Esc(r.Text)}</w:t></w:r>";
            case DocxRunType.Tab:
                return $"<w:r>{RPr(r.Style)}<w:tab/></w:r>";
            case DocxRunType.Blank:
                {
                    var s = r.Style;
                    s.Underline = true;
                    // A no-break space is ~0.25 em wide in the common text faces.
                    double em = (s.Size ?? 11) * 0.25;
                    int n = Math.Max(2, (int)Math.Round(r.Width / em, MidpointRounding.AwayFromZero));
                    return $"<w:r>{RPr(s)}<w:t xml:space=\"preserve\">{new string(' ', n)}</w:t></w:r>";
                }
            default:
                {
                    bool on = r.Checked;
                    string glyph = on ? "☒" : "☐";
                    return $"<w:sdt><w:sdtPr><w14:checkbox><w14:checked w14:val=\"{(on ? 1 : 0)}\"/>"
                        + "<w14:checkedState w14:val=\"2612\" w14:font=\"MS Gothic\"/><w14:uncheckedState w14:val=\"2610\" w14:font=\"MS Gothic\"/>"
                        + "</w14:checkbox></w:sdtPr><w:sdtContent><w:r><w:rPr><w:rFonts w:ascii=\"MS Gothic\" w:eastAsia=\"MS Gothic\" w:hAnsi=\"MS Gothic\"/></w:rPr>"
                        + $"<w:t>{glyph}</w:t></w:r></w:sdtContent></w:sdt>";
                }
        }
    }

    // MARK: - header / footer

    public static string Header(DocxModel m)
    {
        int cx = Emu(m.HeaderWidth), cy = Emu(m.HeaderHeight);
        string ind = "";
        if (m.HeaderOffsetX != 0) ind = $"<w:ind w:left=\"{I(Tw(m.HeaderOffsetX))}\"/>";
        return XmlHead + $"<w:hdr {Ns}><w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/>{ind}</w:pPr><w:r><w:drawing>"
            + $"<wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"{I(cx)}\" cy=\"{I(cy)}\"/><wp:docPr id=\"1\" name=\"Letterhead\"/>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>"
            + "<pic:nvPicPr><pic:cNvPr id=\"0\" name=\"letterhead.png\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"rIdLogo\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + $"<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"{I(cx)}\" cy=\"{I(cy)}\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p></w:hdr>";
    }

    public static readonly string Footer = BuildFooter();

    static string BuildFooter()
    {
        const string rp = "<w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\"/><w:sz w:val=\"16\"/></w:rPr>";
        static string Field(string instr) =>
            $"<w:r>{rp}<w:fldChar w:fldCharType=\"begin\"/></w:r><w:r>{rp}<w:instrText xml:space=\"preserve\"> {instr} </w:instrText></w:r>"
            + $"<w:r>{rp}<w:fldChar w:fldCharType=\"separate\"/></w:r><w:r>{rp}<w:t>1</w:t></w:r><w:r>{rp}<w:fldChar w:fldCharType=\"end\"/></w:r>";
        return XmlHead + $"<w:ftr {Ns}><w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr>"
            + Field("PAGE") + $"<w:r>{rp}<w:t xml:space=\"preserve\"> of </w:t></w:r>" + Field("NUMPAGES") + "</w:p></w:ftr>";
    }

    // MARK: - package parts

    public static string ContentTypes(bool header, bool footer)
    {
        var b = XmlHead + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Default Extension=\"png\" ContentType=\"image/png\"/>"
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
            + "<Override PartName=\"/word/settings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml\"/>"
            + "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
            + "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>";
        if (header) b += "<Override PartName=\"/word/header1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml\"/>";
        if (footer) b += "<Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>";
        return b + "</Types>";
    }

    public const string RootRels = XmlHead + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
        + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
        + "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>"
        + "</Relationships>";

    public static string DocumentRels(bool header, bool footer)
    {
        var b = XmlHead + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            + "<Relationship Id=\"rIdSettings\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings\" Target=\"settings.xml\"/>";
        if (header) b += "<Relationship Id=\"rIdHeader\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/>";
        if (footer) b += "<Relationship Id=\"rIdFooter\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>";
        return b + "</Relationships>";
    }

    public const string HeaderRels = XmlHead + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + "<Relationship Id=\"rIdLogo\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/letterhead.png\"/>"
        + "</Relationships>";

    public static string Styles(DocxModel m)
    {
        var f = Esc(m.BaseFont);
        return XmlHead + $"<w:styles {Ns}>"
            + $"<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"{f}\" w:eastAsia=\"{f}\" w:hAnsi=\"{f}\" w:cs=\"{f}\"/>"
            + $"<w:sz w:val=\"{I(Hp(m.BaseSize))}\"/><w:szCs w:val=\"{I(Hp(m.BaseSize))}\"/><w:lang w:val=\"en-US\"/></w:rPr></w:rPrDefault>"
            + "<w:pPrDefault><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
            + "</w:styles>";
    }

    public const string Settings = XmlHead + "<w:settings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        + "<w:defaultTabStop w:val=\"720\"/><w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>";

    public static string Core(string title)
    {
        var iso = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        return XmlHead + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
            + $"<dc:title>{Esc(title)}</dc:title><dc:creator>Jack (ThinkOpen)</dc:creator>"
            + $"<dcterms:created xsi:type=\"dcterms:W3CDTF\">{iso}</dcterms:created><dcterms:modified xsi:type=\"dcterms:W3CDTF\">{iso}</dcterms:modified>"
            + "</cp:coreProperties>";
    }

    public const string App = XmlHead + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>Jack</Application></Properties>";
}
