// Save as Word — turn a PDF into an editable Word document, entirely on this machine.
//
// Line-for-line port of Sources/WordExportEngine.swift (Jack 3.5.1). Same constants, thresholds,
// ordering and heuristics; CGFloat → double, Float → float (OCR confidence and the deskew
// histogram are single precision on the Mac too). Sorting goes through SwiftSort (Swift's own
// algorithm) so ties and the one non-transitive comparator order exactly as on the Mac.
//
// The honest scope (2026-11-11, reopened after a scanned contract came in for editing):
//   • Text PDFs are read from their text layer; scans are read twice (on the Mac: Vision with and
//     without language correction; on Windows: Windows OCR and Tesseract). Words the two readings
//     disagree on, or that contain characters no document uses, are highlighted yellow in Word —
//     never silently guessed.
//   • Layout is rebuilt, not traced: paragraphs, numbered / lettered items with hanging indents,
//     centered blocks, bold and underline (from ink weight and rules on the page), fill-in lines,
//     checkboxes (real Word checkboxes), a repeated letterhead (one image in the header) and
//     "N of M" page numbers (a live footer field).
//   • Handwriting is never copied. A signature becomes a placeholder line saying so.
//   • Tables and multi-column pages are REFUSED with a reason rather than mangled.
//   • Before the file is kept it is reopened and every written word must read back in order.
//
// The engine reads pages only through IPageSource (no OCR or PDFium calls here).
using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;
using Jack.Core.Imaging;

namespace Jack.Core.Word;

public static class WordExportEngine
{
    public sealed class Options
    {
        public bool MatchPages = true;          // page breaks where the PDF's pages break
        public bool KeepLetterhead = true;      // repeated top-of-page block → one header image
        public bool MarkUncertain = true;       // yellow highlight on words to double-check
    }

    public sealed class Report
    {
        public int Pages;
        public int ScannedPages;
        public int Words;
        public int AgreedWords;
        public int UncertainWords;
        public int LeftOutMarks;
        public int SignaturePlaceholders;
        public int Checkboxes;
        public int CheckedBoxes;
        public bool Letterhead;
        public bool PageNumbers;
        public int? DeclaredPageTotal;
        public double Readback;
        public List<string> Debug = new();

        public (int Lower, int Upper)? MissingPages
        {
            get
            {
                if (DeclaredPageTotal is not int t || !(t > Pages) || !(t - Pages < 500)) return null;
                return (Pages + 1, t);
            }
        }
        public double Agreement => Words == 0 ? 1 : (double)AgreedWords / Words;

        public string Summary
        {
            get
            {
                var s = $"{Pages} page(s), {Words} words";
                s += ScannedPages > 0
                    ? F(" · {0:F1}% read the same twice", Agreement * 100)
                    : F(" · {0:F1}% match the PDF's own text", Agreement * 100);
                if (UncertainWords > 0) s += $" · {UncertainWords} to double-check";
                if (Checkboxes > 0) s += $" · {Checkboxes} checkbox(es), {CheckedBoxes} ticked";
                if (SignaturePlaceholders > 0) s += $" · {SignaturePlaceholders} signature(s) left out";
                if (LeftOutMarks > SignaturePlaceholders) s += $" · {LeftOutMarks - SignaturePlaceholders} unreadable mark(s) left out";
                if (MissingPages is { } m) s += $" · footers say {m.Upper} pages, pages {m.Lower}–{m.Upper} not in this PDF";
                s += F(" · read-back {0:F1}%", Readback * 100);
                return s;
            }
        }
    }

    public enum ErrorKind { Refused, NoText, WriteFailed, VerifyFailed, Cancelled }

    public sealed class ExportException : Exception
    {
        public readonly ErrorKind Kind;
        public readonly string Text;          // .Refused: every word read (for Copy Text)
        public readonly double Readback;      // .VerifyFailed

        public ExportException(ErrorKind kind, string? reason = null, string text = "", double readback = 0)
            : base(Describe(kind, reason, readback))
        {
            Kind = kind; Text = text; Readback = readback;
        }

        static string Describe(ErrorKind k, string? why, double r) => k switch
        {
            ErrorKind.Refused => why ?? "",
            ErrorKind.Cancelled => "Stopped. Nothing was saved.",
            ErrorKind.NoText => "Jack couldn’t find any readable text in this PDF.",
            ErrorKind.WriteFailed => "The Word document couldn’t be written.",
            ErrorKind.VerifyFailed => F("The Word document didn’t check out against the PDF ({0:F0}% of words read back), so Jack didn’t keep it.", r * 100),
            _ => "",
        };
    }

    /// Where the .docx lands: beside the PDF, never clobbering anything.
    public static string OutputPath(string source)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(source)) ?? ".";
        var b = Path.GetFileNameWithoutExtension(source);
        var candidate = Path.Combine(dir, b + ".docx");
        int n = 2;
        while (File.Exists(candidate))
        {
            candidate = Path.Combine(dir, $"{b} {n}.docx");
            n += 1;
        }
        return candidate;
    }

    // MARK: - Model

    public enum Kind { Word, Checkbox, Blank, Note }

    public sealed class Item
    {
        public Kind Kind;
        public string Text;
        public double X0, X1, Y0, Y1;   // points, TOP-LEFT origin
        public bool Bold;
        public bool Underline;
        public bool Uncertain;
        public bool Checked;
        public double Stroke;           // ink stroke width / height (scans)

        public Item(Kind kind, string text, double x0, double x1, double y0, double y1)
        {
            Kind = kind; Text = text; X0 = x0; X1 = x1; Y0 = y0; Y1 = y1;
        }
        public double H => Y1 - Y0;
        public double Cy => (Y0 + Y1) / 2;
    }

    public sealed class Line
    {
        public string Text;
        public double X0, X1, Y0, Y1;
        public float Confidence;
        public List<Item> Items;
        internal int SourceIndex;       // position in the OCR's own order (replay checks the sort)

        public Line(string text, double x0, double x1, double y0, double y1, float confidence, List<Item> items)
        {
            Text = text; X0 = x0; X1 = x1; Y0 = y0; Y1 = y1; Confidence = confidence; Items = items;
        }
    }

    public readonly record struct Rule(double X0, double X1, double Y);

    public sealed class PageData
    {
        public readonly int Index;
        public readonly double Width, Height;
        public List<Line> Lines = new();
        public List<Item> Extras = new();
        public List<Rule> Rules = new();
        public List<Line> Dropped = new();
        public bool IsScan;
        public GrayImage? Gray;
        public PageData(int index, double width, double height) { Index = index; Width = width; Height = height; }
    }

    public const double RenderScale = 4.0;     // 288 dpi, same as Make Searchable

    static readonly bool DebugBoxes = Environment.GetEnvironmentVariable("JACK_WORD_DEBUG_BOXES") != null;

    // MARK: - Entry point

    /// Convert the document behind `src` to a .docx at `outPath`. Throws ExportException
    /// (Refused / NoText / VerifyFailed / WriteFailed / Cancelled); on any throw nothing is left at
    /// `outPath`. `progress` gets (pageIndex, pageCount) while reading.
    public static Report Export(IPageSource src, string outPath, string title, Options? options = null,
                                Action<int, int>? progress = null, Func<bool>? cancelled = null)
    {
        options ??= new Options();
        LastLetterheadPixels = null;
        var report = new Report { Pages = src.PageCount };
        if (src.PageCount <= 0) throw new ExportException(ErrorKind.NoText);

        // 1. Read every page.
        var pages = new List<PageData>();
        for (int i = 0; i < src.PageCount; i++)
        {
            progress?.Invoke(i, src.PageCount);
            if (cancelled?.Invoke() == true) throw new ExportException(ErrorKind.Cancelled);
            var pd = Read(src, i, report);
            pages.Add(pd);
        }
        var allWords = pages.SelectMany(p => p.Lines.SelectMany(l => l.Items)).Where(w => w.Kind == Kind.Word).ToList();
        if (!(allWords.Count >= 3)) throw new ExportException(ErrorKind.NoText);

        // 2. Letterhead and page-number footer.
        var hf = DetectHeaderFooter(pages, report);

        // 3. Ink: underline / fill-in lines, bold (scans), checkboxes.
        foreach (var p in pages)
            Decorate(p, options.KeepLetterhead && hf.HeaderBottom.TryGetValue(p.Index, out var hb) ? hb : null);

        // 4. Rows, refusal checks, paragraphs.
        var rowsByPage = new List<List<Row>>();
        foreach (var p in pages) rowsByPage.Add(BuildRows(p, hf, options.KeepLetterhead, report));
        if (Refusal(rowsByPage, pages) is string why)
        {
            var text = string.Join("\n\n", rowsByPage.Select(rows =>
                string.Join("\n", rows.Select(r => string.Join(" ", r.Words.Select(w => w.Text))).Where(s => s.Length > 0))));
            throw new ExportException(ErrorKind.Refused, why, text);
        }
        if (cancelled?.Invoke() == true) throw new ExportException(ErrorKind.Cancelled);
        progress?.Invoke(src.PageCount, src.PageCount);

        var model = new DocxModel { Title = title };
        var geo = Geometry(pages, rowsByPage);
        model.PageWidth = pages[0].Width;
        model.PageHeight = pages[0].Height;
        model.MarginLeft = geo.Left;
        model.MarginRight = Math.Max(36, pages[0].Width - geo.Right);
        model.MarginBottom = 54;
        model.BaseSize = geo.BaseSize;
        model.BaseFont = geo.Font;
        report.Debug.Add(F("geometry: left {0:F1} right {1:F1} bodyH {2:F2} base {3:F1}pt font {4}", geo.Left, geo.Right, geo.BodyH, geo.BaseSize, geo.Font));

        if (options.KeepLetterhead && hf.Letterhead is { } lh && LetterheadPNG(src, lh) is { } png)
        {
            model.HeaderPNG = png.Data;
            model.HeaderWidth = png.Width;
            model.HeaderHeight = png.Height;
            model.HeaderDistance = Math.Max(18, lh.Rect.MinY);
            model.HeaderOffsetX = lh.Rect.MinX - geo.Left;
            model.MarginTop = Math.Max(model.HeaderDistance + png.Height + 10, geo.Top);
            report.Letterhead = true;
        }
        else
        {
            model.MarginTop = Math.Max(36, geo.Top);
        }
        model.PageNumberFooter = hf.PageNumbers;
        report.PageNumbers = hf.PageNumbers;

        var written = new List<string>();
        model.Paragraphs = Paragraphs(rowsByPage, pages, geo, model.MarginTop, options, report, written);

        // 5. Write, then prove it: reopen and require every written word back, in order.
        try { DocxWriter.Write(model, outPath); }
        catch (Exception) { throw new ExportException(ErrorKind.WriteFailed); }
        var back = ReadBack(outPath);
        report.Readback = InOrderRatio(written, back ?? new List<string>());
        if (report.Readback < 0.985)
        {
            try { File.Delete(outPath); } catch { }
            throw new ExportException(ErrorKind.VerifyFailed, readback: report.Readback);
        }
        return report;
    }

    // MARK: - 1. Reading

    public static PageData Read(IPageSource src, int index, Report report)
    {
        var info = src.Page(index);
        var pd = new PageData(index, info.Width, info.Height);
        pd.Gray = src.Render(index);
        var existing = SwiftText.TrimWhitespacesAndNewlines(info.TextLayer);
        // Every page is read from its rendered image (one layout path for all PDFs). The second,
        // independent reading is the PDF's own text layer when it has a trustworthy one, or a
        // second OCR pass (no language correction / another engine) when it's a scan.
        bool textLayer = SwiftText.Count(existing) > 20 && !info.IsScanPage;
        if (pd.Gray is not GrayImage g) return pd;
        if (!textLayer)
        {
            pd.IsScan = true; report.ScannedPages += 1;
            // A scan fed in at an angle: straighten it before anything reads it, or neighbouring
            // lines drift into each other and their words get woven together. Every word would
            // still read right, so the two readings could not catch it.
            double skew = EstimateSkew(g);
            if (Math.Abs(skew) >= 0.15 && Rotated(src, index, g, skew) is GrayImage straight)
            {
                g = straight;
                pd.Gray = straight;
                report.Debug.Add(F("p{0} deskewed {1:F2}° (left {2:F2}°)", index + 1, skew, EstimateSkew(straight)));
            }
        }
        var first = Recognize(src, index, g, info.Width, info.Height, correction: true);
        var kept = new List<Line>();
        foreach (var l in first)
        {
            // Handwriting and smudges come back at low confidence: never copy them.
            if (l.Confidence < 0.35f || SwiftText.TrimWhitespaces(l.Text).Length == 0) { pd.Dropped.Add(l); continue; }
            kept.Add(l);
        }
        var a = kept.SelectMany(l => l.Items).ToList();
        List<string> second = textLayer
            ? SwiftText.SplitWhitespacesAndNewlines(existing).Select(Norm).Where(s => s.Length > 0).ToList()
            : Recognize(src, index, g, info.Width, info.Height, correction: false).Where(l => l.Confidence >= 0.35f)
                .SelectMany(l => l.Items).Select(w => Norm(w.Text)).ToList();
        var agreed = LcsMatches(a.Select(w => Norm(w.Text)).ToList(), second);
        for (int i = 0; i < a.Count; i++)
        {
            var w = a[i];
            var n = Norm(w.Text);
            if ((!agreed.Contains(i) && SwiftText.Count(n) > 1) || LooksGarbled(w.Text)) w.Uncertain = true;
        }
        pd.Lines = kept;
        report.Debug.Add($"p{index + 1} {(textLayer ? "text" : "scan")}: {first.Count} lines, dropped {pd.Dropped.Count}");
        return pd;
    }

    /// The page's tilt in degrees (positive = text lines fall to the right), from a projection
    /// profile: lines of text make the sharpest row histogram when they are counted along their
    /// own slope. Returns 0 when there is too little ink or no clear peak (a photo, a blank page).
    /// Single precision throughout, as on the Mac (Float, tanf, Float.pi rounded toward zero).
    public static double EstimateSkew(GrayImage g)
    {
        const int step = 3;
        var xs = new List<float>(); var ys = new List<float>();
        for (int r = 0; r < g.H; r += step)
        {
            int b = r * g.W;
            for (int c = 0; c < g.W; c += step)
                if (g.Px[b + c] < 150) { xs.Add(c); ys.Add(r); }
        }
        if (!(xs.Count > 1500)) return 0;
        // One bin per sampled row. A bin height that is not the sampling step aliases: at exactly
        // 0° some bins are always empty, which inflates the score there and hides tilts under ~1°.
        float binH = step;
        float off = (float)g.W * 0.08f;                     // room for a 4° slope
        int nb = (int)(((float)g.H + 2 * off) / binH) + 2;
        var bins = new int[nb];
        var X = xs.ToArray(); var Y = ys.ToArray();
        double Score(float deg)
        {
            float t = MathF.Tan(deg * SwiftFloatPi / 180f);
            Array.Clear(bins);
            for (int i = 0; i < X.Length; i++)
            {
                int b = (int)((Y[i] - X[i] * t + off) / binH);
                if (b >= 0 && b < nb) bins[b] += 1;
            }
            double s = 0.0;
            foreach (var v in bins) s += (double)v * (double)v;
            return s;
        }
        double flat = Score(0);
        float best = 0; double bestScore = flat;
        for (int k = -40; k <= 40; k++)
        {
            if (k == 0) continue;
            float d = (float)k * 0.1f; double sc = Score(d);
            if (sc > bestScore) { bestScore = sc; best = d; }
        }
        float fine = best;
        for (int k = -9; k <= 9; k++)
        {
            if (k == 0) continue;
            float d = best + (float)k * 0.01f; double sc = Score(d);
            if (sc > bestScore) { bestScore = sc; fine = d; }
        }
        if (Environment.GetEnvironmentVariable("JACK_WORD_DEBUG_SKEW") != null)
            Console.WriteLine(F("skew: points {0} best {1:F2}° ratio {2:F4}", xs.Count, fine, bestScore / flat));
        if (!(bestScore > flat * 1.03)) return 0;
        return fine;
    }

    /// Swift's Float.pi is π rounded toward zero (0x40490FDA), one ulp below MathF.PI.
    static readonly float SwiftFloatPi = BitConverter.Int32BitsToSingle(0x40490FDA);

    /// `g` turned by `degrees` (counter-clockwise as seen) about its centre, on white.
    static GrayImage? Rotated(IPageSource src, int index, GrayImage g, double degrees)
        => src.RotatedOverride(index, g, degrees) ?? Imaging.Rotate.Gray(g, degrees);

    static List<Line> Recognize(IPageSource src, int index, GrayImage g, double W, double H, bool correction)
    {
        var lines = new List<Line>();
        var obs = src.Recognize(index, g, W, H, correction);
        for (int k = 0; k < obs.Count; k++)
        {
            var o = obs[k];
            var items = o.Words.Select(w => new Item(Kind.Word, w.Text, w.X0, w.X1, w.Y0, w.Y1)).ToList();
            lines.Add(new Line(o.Text, o.X0, o.X1, o.Y0, o.Y1, o.Confidence, items) { SourceIndex = k });
        }
        // Reading order: top to bottom, then left to right.
        SwiftSort.Sort(lines, (a, b) => Math.Abs(a.Y0 - b.Y0) > Math.Min(a.Y1 - a.Y0, b.Y1 - b.Y0) * 0.5 ? a.Y0 < b.Y0 : a.X0 < b.X0);
        src.SortedOrder(index, correction, lines.Select(l => l.SourceIndex).ToList());
        return lines;
    }

    // MARK: - 2. Letterhead and footer

    public sealed class HeaderFooter
    {
        public HashSet<string> HeaderKeys = new();
        public HashSet<string> FooterLineIDs = new();          // "page:lineIndex" of page-number lines
        public Dictionary<int, double> HeaderBottom = new();   // per page, y below which the body starts
        public (int Page, Rect Rect)? Letterhead;
        public bool PageNumbers;
    }

    static readonly Regex PageNumberRx = new(@"^\s*(page\s*)?(\d{1,4})\s*(of|/)\s*(\d{1,4})?\s*$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static HeaderFooter DetectHeaderFooter(List<PageData> pages, Report report)
    {
        var hf = new HeaderFooter();
        // Page numbers ("4 of 16", "Page 2", "2/9") in the bottom band.
        foreach (var p in pages)
        {
            for (int li = 0; li < p.Lines.Count; li++)
            {
                var l = p.Lines[li];
                if (!(l.Y0 > p.Height * 0.86)) continue;
                var m = PageNumberRx.Match(l.Text);
                if (m.Success)
                {
                    hf.FooterLineIDs.Add($"{p.Index}:{li}");
                    hf.PageNumbers = true;
                    if (m.Groups[4].Success && SwiftText.SwiftInt(m.Groups[4].Value) is int total)
                        report.DeclaredPageTotal = Math.Max(report.DeclaredPageTotal ?? 0, total);
                }
            }
        }
        // Letterhead: top-band lines that repeat on at least half the pages (2+).
        if (!(pages.Count >= 2)) return hf;
        var counts = new Dictionary<string, int>();
        foreach (var p in pages)
        {
            var seen = new HashSet<string>();
            foreach (var l in p.Lines)
            {
                if (!(l.Y1 < p.Height * 0.17)) continue;
                var k = Norm(l.Text);
                if (SwiftText.Count(k) >= 3) seen.Add(k);
            }
            foreach (var k in seen) counts[k] = counts.GetValueOrDefault(k) + 1;
        }
        int need = Math.Max(2, (int)Math.Ceiling(pages.Count * 0.5));
        hf.HeaderKeys = counts.Where(kv => kv.Value >= need).Select(kv => kv.Key).ToHashSet();
        if (hf.HeaderKeys.Count == 0) return hf;
        foreach (var p in pages)
        {
            var hl = p.Lines.Where(l => l.Y1 < p.Height * 0.17 && hf.HeaderKeys.Contains(Norm(l.Text))).ToList();
            if (hl.Count == 0) continue;
            double bottom = hl.Select(l => l.Y1).Max();
            hf.HeaderBottom[p.Index] = bottom + 3;
            if (hf.Letterhead == null && p.Gray is GrayImage g)
            {
                // The letterhead block: every mark between the page top and the header text's bottom.
                if (InkBounds(g, new Rect(0, 0, p.Width, bottom + 3)) is Rect r)
                    hf.Letterhead = (p.Index, r);
            }
        }
        return hf;
    }

    /// Bounding box (points) of the ink inside `rect` (points, top-left), ignoring a thin page edge.
    public static Rect? InkBounds(GrayImage g, Rect rect)
    {
        double s = g.Scale;
        int edge = (int)(6 * s);
        int c0 = Math.Max(edge, (int)(rect.MinX * s)), c1 = Math.Min(g.W - edge, (int)(rect.MaxX * s));
        int r0 = Math.Max(edge, (int)(rect.MinY * s)), r1 = Math.Min(g.H - edge, (int)(rect.MaxY * s));
        if (!(c1 > c0 && r1 > r0)) return null;
        int minC = int.MaxValue, maxC = -1, minR = int.MaxValue, maxR = -1;
        for (int r = r0; r < r1; r++)
        {
            bool any = false;
            for (int c = c0; c < c1; c++)
            {
                if (!(g.Px[r * g.W + c] < 200)) continue;
                any = true;
                if (c < minC) minC = c;
                if (c > maxC) maxC = c;
            }
            if (any) { if (r < minR) minR = r; maxR = r; }
        }
        if (!(maxC > minC && maxR > minR)) return null;
        const double pad = 2;
        return new Rect((double)minC / s - pad, (double)minR / s - pad,
                        (double)(maxC - minC) / s + pad * 2, (double)(maxR - minR) / s + pad * 2);
    }

    /// Render the letterhead block in colour and trim it — it becomes the header picture.
    static (byte[] Data, double Width, double Height)? LetterheadPNG(IPageSource src, (int Page, Rect Rect) lh)
    {
        if (lh.Page < 0 || lh.Page >= src.PageCount) return null;
        const double s = 3;
        var r = lh.Rect;
        int w = (int)(r.W * s), h = (int)(r.H * s);
        if (!(w > 4 && h > 4)) return null;
        if (src.RenderColorCrop(lh.Page, r, s, w, h) is not byte[] p || p.Length != w * h * 4) return null;
        // Paper is never pure white in a scan — lift near-white to white so the header sits clean.
        int n = w * h;
        for (int i = 0; i < n; i++)
        {
            int o = i * 4;
            byte rr = p[o], gg = p[o + 1], bb = p[o + 2];
            if (Math.Min(rr, Math.Min(gg, bb)) > 196 && Math.Max(rr, Math.Max(gg, bb)) - Math.Min(rr, Math.Min(gg, bb)) < 34) { p[o] = 255; p[o + 1] = 255; p[o + 2] = 255; }
        }
        var png = Png.Encode(w, h, 4, p);
        LastLetterheadPixels = p;
        return (png, r.Width, r.Height);
    }

    /// The lifted letterhead pixels of the last export (replay compares them with the Mac's).
    public static byte[]? LastLetterheadPixels { get; private set; }

    // MARK: - 3. Ink: rules, underline, bold, checkboxes

    public static void Decorate(PageData p, double? headerBottom)
    {
        if (p.Gray is not GrayImage g) return;
        double floorY = headerBottom ?? 0;
        p.Rules = FindRules(g).Where(r => r.Y > floorY).ToList();
        var words = p.Lines.SelectMany(l => l.Items).ToList();

        // Checkboxes first, so a box OCR'd as a letter can be dropped.
        {
            foreach (var cb in FindSquares(g))
            {
                if (!(cb.Y0 > floorY)) continue;
                // A square made of a word's own lettering is a letter, not a box: the bowl of a bold
                // "o", "a" or "P" in a heading draws a closed outline, and strokes of two lines of
                // tight text can close one too. Either the word starts well before the square, or the
                // square is much shorter or much taller than the word it sits in (a real box is about
                // as tall as its label, even when OCR glues the tick onto the label).
                double bw = cb.X1 - cb.X0, bh = cb.Y1 - cb.Y0;
                bool inLettering = words.Any(w =>
                    SwiftText.Count(w.Text) > 2 && w.X0 < cb.X1 - bw * 0.5 && w.X1 > cb.X1 + 1
                    && Math.Min(w.Y1, cb.Y1) - Math.Max(w.Y0, cb.Y0) > Math.Min(bh, w.H) * 0.5
                    && (w.X0 < cb.X0 - Math.Max(2, bw * 0.3) || bh < w.H * 0.6 || bh > w.H * 1.6));
                if (inLettering) continue;
                // A real box sits on light paper. Light text on a dark band (a cover banner) turns
                // the gaps between letters into "outlines": the ring around them is mostly ink.
                var outer = new Rect(cb.X0 - 3, cb.Y0 - 3, bw + 6, bh + 6);
                double outerArea = outer.W * outer.H, boxArea = bw * bh;
                double ringInk = (InkFraction(g, outer) * outerArea - InkFraction(g, new Rect(cb.X0, cb.Y0, bw, bh)) * boxArea)
                    / Math.Max(1, outerArea - boxArea);
                if (ringInk > 0.45) continue;      // measured: real boxes ≤ 0.36, banner gaps mostly 0.45–0.95
                // A real checkbox has its label right after it; logo shapes and frames don't.
                // (The label may start INSIDE the box: a tick that overshoots gets read as its first letter.)
                bool labelled = words.Any(w => w.X1 > cb.X1 + 4 && w.X0 < cb.X1 + 40 && Math.Abs(w.Cy - cb.Cy) < Math.Max(cb.Y1 - cb.Y0, w.H));
                if (!labelled) continue;
                foreach (var w in words)
                {
                    if (!(w.X0 < cb.X1 - 1 && w.X1 > cb.X1 + 4 && Math.Abs(w.Cy - cb.Cy) < Math.Max(cb.Y1 - cb.Y0, w.H))) continue;
                    // Strip the tick that OCR glued onto the label ("√Comprehensive", "VGeneral").
                    var t = SwiftText.Characters(w.Text);
                    int start = 0;
                    while (t.Count - start > 0 && Tickish.Contains(t[start]) && t.Count - start > 1
                           && (SwiftText.CharIsUppercase(t[start + 1]) || !SwiftText.CharIsLetter(t[start + 1])))
                        start++;
                    if (t.Count - start != SwiftText.Count(w.Text)) { w.Text = string.Concat(t.Skip(start)); w.X0 = cb.X1 + 1; }
                }
                p.Extras.Add(cb);
                if (DebugBoxes)
                {
                    var near = string.Join(" ", SwiftSort.Sorted(words.Where(w => Math.Abs(w.Cy - cb.Cy) < 10 && w.X0 >= cb.X0 - 4), (a, b) => a.X0 < b.X0).Take(3).Select(w => w.Text));
                    Console.WriteLine(F("box p{0} x {1:F0}-{2:F0} y {3:F0}-{4:F0} checked {5} next: {6}", p.Index + 1, cb.X0, cb.X1, cb.Y0, cb.Y1, cb.Checked ? 1 : 0, near));
                }
            }
            if (p.Extras.Count > 0)
            {
                foreach (var line in p.Lines)
                    line.Items.RemoveAll(w => p.Extras.Any(cb => Overlap(w, cb) > 0.5 && SwiftText.Count(w.Text) <= 2));
            }
        }

        // A checkbox's top and bottom edges are not rules.
        var boxes = p.Extras.Where(e => e.Kind == Kind.Checkbox).ToList();
        p.Rules.RemoveAll(r => boxes.Any(b => r.X0 > b.X0 - 3 && r.X1 < b.X1 + 3 && r.Y > b.Y0 - 2 && r.Y < b.Y1 + 2));

        // Underline: a rule just under a word, spanning most of it.
        var covered = new List<(double, double)>[p.Rules.Count];
        for (int i = 0; i < covered.Length; i++) covered[i] = new();
        foreach (var w in words)
        {
            for (int ri = 0; ri < p.Rules.Count; ri++)
            {
                var r = p.Rules[ri];
                double ov = Math.Min(w.X1, r.X1) - Math.Max(w.X0, r.X0);
                if (!(ov > (w.X1 - w.X0) * 0.6)) continue;
                if (r.Y > w.Y1 - w.H * 0.35 && r.Y < w.Y1 + w.H * 0.45)
                {
                    w.Underline = true;
                    covered[ri].Add((w.X0, w.X1));
                }
            }
        }
        // What's left of each rule is a fill-in line.
        for (int ri = 0; ri < p.Rules.Count; ri++)
        {
            var r = p.Rules[ri];
            var spans = SwiftSort.Sorted(covered[ri], (a, b) => a.Item1 < b.Item1);
            var pieces = new List<(double, double)>();
            if (spans.Count > 0)
            {
                var first = spans[0]; var last = spans[^1];
                if (first.Item1 - r.X0 > 18) pieces.Add((r.X0, first.Item1));
                if (r.X1 - last.Item2 > 18) pieces.Add((last.Item2, r.X1));
            }
            else if (r.X1 - r.X0 > 18)
            {
                pieces.Add((r.X0, r.X1));
            }
            foreach (var (a, b) in pieces)
            {
                // Ink of a word sitting on the line means it's that word's underline, not a blank.
                bool onIt = words.Any(w => Math.Min(w.X1, b) - Math.Max(w.X0, a) > 2 && r.Y > w.Y0 && r.Y < w.Y1 + w.H * 0.5);
                if (onIt) continue;
                p.Extras.Add(new Item(Kind.Blank, "", a, b, r.Y - 9, r.Y));
            }
        }

        // Bold (scans): ink stroke width relative to the page's typical stroke.
        {
            foreach (var w in words) w.Stroke = StrokeRatio(g, w);
            var vals = SwiftSort.Sorted(words.Where(w => SwiftText.Count(w.Text) >= 3 && w.Stroke > 0).Select(w => w.Stroke));
            if (vals.Count > 10)
            {
                double med = vals[vals.Count / 2];
                foreach (var w in words) if (w.Stroke > med * 1.32 && SwiftText.Count(w.Text) >= 2) w.Bold = true;
                // Smooth: bold is a property of phrases, not of one letter group in a sentence.
                foreach (var line in p.Lines)
                {
                    var its = line.Items;
                    if (!(its.Count >= 3)) continue;
                    for (int k = 1; k < its.Count - 1; k++)
                        if (its[k].Bold && !its[k - 1].Bold && !its[k + 1].Bold && !its[k].Underline) its[k].Bold = false;
                    for (int k = 1; k < its.Count - 1; k++)
                        if (!its[k].Bold && its[k - 1].Bold && its[k + 1].Bold) its[k].Bold = true;
                }
            }
        }
    }

    static readonly HashSet<string> Tickish = SwiftText.Characters("√✓✔/|\\VvJjIl1").ToHashSet();

    struct Seg { public int C0, C1, R0, R1; }

    /// Long, thin, horizontal dark runs: underlines, fill-in lines, signature lines.
    public static List<Rule> FindRules(GrayImage g)
    {
        double s = g.Scale;
        int minRun = (int)(16 * s);
        int maxThick = (int)(3.6 * s);
        var open = new List<Seg>();
        var done = new List<Seg>();
        var px = g.Px;
        var runs = new List<(int, int)>();
        for (int r = 0; r < g.H; r++)
        {
            runs.Clear();
            int c = 0;
            int bse = r * g.W;
            while (c < g.W)
            {
                if (px[bse + c] < 150)
                {
                    int start = c;
                    int gap = 0;
                    int end = c;
                    while (c < g.W)
                    {
                        if (px[bse + c] < 150) { end = c; gap = 0; } else { gap += 1; if (gap > 3) break; }
                        c += 1;
                    }
                    if (end - start >= minRun) runs.Add((start, end));
                }
                else c += 1;
            }
            var next = new List<Seg>();
            var used = new bool[runs.Count];
            foreach (var sg0 in open)
            {
                var sg = sg0;
                bool extended = false;
                for (int k = 0; k < runs.Count; k++)
                {
                    if (used[k]) continue;
                    var run = runs[k];
                    int ov = Math.Min(sg.C1, run.Item2) - Math.Max(sg.C0, run.Item1);
                    if (ov > Math.Min(sg.C1 - sg.C0, run.Item2 - run.Item1) / 2)
                    {
                        sg.C0 = Math.Min(sg.C0, run.Item1); sg.C1 = Math.Max(sg.C1, run.Item2); sg.R1 = r;
                        used[k] = true; extended = true;
                        break;
                    }
                }
                if (extended) next.Add(sg); else done.Add(sg);
            }
            for (int k = 0; k < runs.Count; k++)
                if (!used[k]) next.Add(new Seg { C0 = runs[k].Item1, C1 = runs[k].Item2, R0 = r, R1 = r });
            open = next;
        }
        done.AddRange(open);
        return SwiftSort.Sorted(done.Where(sg => sg.R1 - sg.R0 + 1 <= maxThick)
                .Select(sg => new Rule((double)sg.C0 / s, (double)sg.C1 / s, (double)(sg.R0 + sg.R1) / 2 / s)),
            (a, b) => a.Y < b.Y);
    }

    // (The Mac file also has findCheckboxes(), a Vision rectangle-detector pass. Nothing calls it
    // in 3.5.1 — decorate() uses findSquares() — so it is not ported.)

    /// Checkboxes: two short horizontal edges of equal length, one a box-height above the other,
    /// joined by inked vertical sides. The tick inside decides checked.
    public static List<Item> FindSquares(GrayImage g)
    {
        double s = g.Scale;
        int minRun = (int)(6.5 * s), maxRun = (int)(24 * s), maxThick = (int)(3 * s);
        var open = new List<Seg>(); var done = new List<Seg>();
        var px = g.Px;
        var runs = new List<(int, int)>();
        for (int r = 0; r < g.H; r++)
        {
            runs.Clear();
            int c = 0;
            int bse = r * g.W;
            while (c < g.W)
            {
                if (px[bse + c] < 150)
                {
                    int start = c;
                    int gap = 0, end = c;
                    while (c < g.W)
                    {
                        if (px[bse + c] < 150) { end = c; gap = 0; } else { gap += 1; if (gap > 1) break; }
                        c += 1;
                    }
                    int len = end - start;
                    if (len >= minRun && len <= maxRun) runs.Add((start, end));
                }
                else c += 1;
            }
            var next = new List<Seg>();
            var used = new bool[runs.Count];
            foreach (var sg0 in open)
            {
                var sg = sg0;
                bool ext = false;
                for (int k = 0; k < runs.Count; k++)
                {
                    var run = runs[k];
                    if (!(!used[k] && Math.Abs(run.Item1 - sg.C0) <= 3 && Math.Abs(run.Item2 - sg.C1) <= 3)) continue;
                    sg.R1 = r; used[k] = true; ext = true; break;
                }
                if (ext) next.Add(sg); else done.Add(sg);
            }
            for (int k = 0; k < runs.Count; k++)
                if (!used[k]) next.Add(new Seg { C0 = runs[k].Item1, C1 = runs[k].Item2, R0 = r, R1 = r });
            open = next;
        }
        done.AddRange(open);
        var edges = SwiftSort.Sorted(done.Where(sg => sg.R1 - sg.R0 + 1 <= maxThick), (a, b) => a.R0 < b.R0);
        var @out = new List<Item>();
        for (int i = 0; i < edges.Count; i++)
        {
            var top = edges[i];
            int len = top.C1 - top.C0;
            for (int bi = i + 1; bi < edges.Count; bi++)
            {
                var bot = edges[bi];
                int dy = bot.R0 - top.R0;
                if (dy > (int)((double)len * 1.4)) break;
                if (!(dy >= (int)((double)len * 0.7) && Math.Abs(bot.C0 - top.C0) <= (int)(2 * s) && Math.Abs(bot.C1 - top.C1) <= (int)(2 * s))) continue;
                double x0 = (double)Math.Min(top.C0, bot.C0) / s, x1 = (double)Math.Max(top.C1, bot.C1) / s;
                double y0 = (double)top.R0 / s, y1 = (double)bot.R1 / s;
                const double side = 1.4;
                double left = InkFraction(g, new Rect(x0 - 0.3, y0, side, y1 - y0));
                double right = InkFraction(g, new Rect(x1 - side + 0.3, y0, side, y1 - y0));
                if (!(left > 0.45 && right > 0.45 && y1 - y0 >= 6)) continue;
                // One box, one entry: drop a candidate that mostly overlaps one already kept.
                if (@out.Any(o =>
                {
                    double ix = Math.Min(o.X1, x1) - Math.Max(o.X0, x0), iy = Math.Min(o.Y1, y1) - Math.Max(o.Y0, y0);
                    return ix > 0 && iy > 0 && ix * iy > 0.5 * Math.Min((o.X1 - o.X0) * (o.Y1 - o.Y0), (x1 - x0) * (y1 - y0));
                })) continue;
                double inner = InkFraction(g, new Rect(x0 + (x1 - x0) * 0.22, y0 + (y1 - y0) * 0.22,
                                                      (x1 - x0) * 0.56, (y1 - y0) * 0.56));
                var it = new Item(Kind.Checkbox, "", x0, x1, y0, y1);
                it.Checked = inner > 0.12;
                @out.Add(it);
                break;
            }
        }
        return @out;
    }

    public static double InkFraction(GrayImage g, Rect r)
    {
        double s = g.Scale;
        int c0 = Math.Max(0, (int)(r.MinX * s)), c1 = Math.Min(g.W, (int)(r.MaxX * s));
        int r0 = Math.Max(0, (int)(r.MinY * s)), r1 = Math.Min(g.H, (int)(r.MaxY * s));
        if (!(c1 > c0 && r1 > r0)) return 0;
        int dark = 0;
        for (int y = r0; y < r1; y++) for (int x = c0; x < c1; x++) if (g.Px[y * g.W + x] < 150) dark += 1;
        return (double)dark / (double)((c1 - c0) * (r1 - r0));
    }

    public static double InkFractionExcludingRules(GrayImage g, Rect r, List<double> ruleYs)
    {
        double s = g.Scale;
        int c0 = Math.Max(0, (int)(r.MinX * s)), c1 = Math.Min(g.W, (int)(r.MaxX * s));
        int r0 = Math.Max(0, (int)(r.MinY * s)), r1 = Math.Min(g.H, (int)(r.MaxY * s));
        if (!(c1 > c0 && r1 > r0)) return 0;
        int dark = 0, total = 0;
        for (int y = r0; y < r1; y++)
        {
            double yp = (double)y / s;
            if (ruleYs.Any(ry => Math.Abs(ry - yp) < 2)) continue;
            for (int x = c0; x < c1; x++) { total += 1; if (g.Px[y * g.W + x] < 150) dark += 1; }
        }
        return total == 0 ? 0 : (double)dark / total;
    }

    /// Mean horizontal stroke width inside the word's x-height band, divided by the word height.
    public static double StrokeRatio(GrayImage g, Item w)
    {
        double s = g.Scale;
        int c0 = Math.Max(0, (int)(w.X0 * s)), c1 = Math.Min(g.W, (int)(w.X1 * s));
        int r0 = Math.Max(0, (int)((w.Y0 + w.H * 0.25) * s)), r1 = Math.Min(g.H, (int)((w.Y1 - w.H * 0.3) * s));
        if (!(c1 > c0 + 2 && r1 > r0)) return 0;
        int runs = 0, dark = 0;
        for (int y = r0; y < r1; y++)
        {
            bool inRun = false;
            for (int x = c0; x < c1; x++)
            {
                if (g.Px[y * g.W + x] < 150) { dark += 1; if (!inRun) { runs += 1; inRun = true; } } else inRun = false;
            }
        }
        if (!(runs > 0)) return 0;
        return (double)dark / (double)runs / s / Math.Max(1, w.H);
    }

    public static double Overlap(Item a, Item b)
    {
        double ix = Math.Min(a.X1, b.X1) - Math.Max(a.X0, b.X0), iy = Math.Min(a.Y1, b.Y1) - Math.Max(a.Y0, b.Y0);
        if (!(ix > 0 && iy > 0)) return 0;
        return (ix * iy) / Math.Max(1, (a.X1 - a.X0) * a.H);
    }

    // MARK: - 4. Rows and paragraphs

    public sealed class Row
    {
        public List<Item> Items;
        public Row(List<Item> items) { Items = items; }
        public List<Item> Words => Items.Where(i => i.Kind == Kind.Word).ToList();
        public double X0 => Items.Count == 0 ? 0 : Items.Min(i => i.X0);
        public double X1 => Items.Count == 0 ? 0 : Items.Max(i => i.X1);
        public double Y0
        {
            get
            {
                var nb = Items.Where(i => i.Kind != Kind.Blank).ToList();
                if (nb.Count > 0) return nb.Min(i => i.Y0);
                return Items.Count == 0 ? 0 : Items.Min(i => i.Y0);
            }
        }
        public double Y1 => Items.Count == 0 ? 0 : Items.Max(i => i.Y1);
        public double Cy => (Y0 + Y1) / 2;
        public double H
        {
            get
            {
                var hs = SwiftSort.Sorted(Words.Select(w => w.H));
                return hs.Count == 0 ? Math.Max(8, Y1 - Y0) : hs[hs.Count / 2];
            }
        }
        public int Segments = 1;
        public bool Centered;
    }

    public static List<Row> BuildRows(PageData p, HeaderFooter hf, bool keepLetterhead, Report report)
    {
        var items = new List<Item>();
        double hb = keepLetterhead ? hf.HeaderBottom.GetValueOrDefault(p.Index, 0) : 0;
        for (int li = 0; li < p.Lines.Count; li++)
        {
            var l = p.Lines[li];
            if (hf.FooterLineIDs.Contains($"{p.Index}:{li}")) continue;
            if (keepLetterhead && hb > 0 && l.Y1 <= hb && hf.HeaderKeys.Contains(Norm(l.Text))) continue;
            if (keepLetterhead && hb > 0 && l.Y1 <= hb) continue;   // anything else inside the letterhead block
            items.AddRange(l.Items);
        }
        items.AddRange(p.Extras.Where(e => e.Y0 >= hb));
        report.Checkboxes += p.Extras.Count(e => e.Kind == Kind.Checkbox);
        report.CheckedBoxes += p.Extras.Count(e => e.Kind == Kind.Checkbox && e.Checked);

        // Handwriting is left out; a signature gets a placeholder that says so.
        report.LeftOutMarks += p.Dropped.Count;
        foreach (var d in p.Dropped)
        {
            if (!(d.Y0 >= hb)) continue;
            bool below = p.Lines.Any(l => l.Y0 > d.Y0 && l.Y0 - d.Y1 < 40 && SwiftText.Lower(l.Text).Contains("signat", StringComparison.Ordinal));
            if (below)
            {
                var note = new Item(Kind.Note, "Signed on executed original", d.X0, Math.Max(d.X1, d.X0 + 120), d.Y0, d.Y1);
                items.Add(note);
                report.SignaturePlaceholders += 1;
            }
        }

        if (p.Gray is GrayImage g)
        {
            var labels = items.Where(i => i.Kind == Kind.Word && SwiftText.Lower(i.Text).StartsWith("signat", StringComparison.Ordinal)).ToList();
            foreach (var lab in labels)
            {
                // The label's row starts at the first word left of it on the same line.
                var rowWords = items.Where(i => i.Kind == Kind.Word && Math.Abs(i.Cy - lab.Cy) < lab.H * 0.6 && i.X1 <= lab.X1).ToList();
                double rx0 = rowWords.Count > 0 ? rowWords.Min(i => i.X0) : lab.X0;
                // A scrawl OCR read as a stray word ("n", "~") is part of the signature, not a
                // line of text above it: it must not cap the search, and it is not copied.
                bool IsScrawl(Item w) =>
                    w.Kind == Kind.Word && w.Y0 > lab.Y0 - 48 && w.Y1 < lab.Y0 - 1 && w.X1 > rx0 - 10 && w.X0 < rx0 + 240
                    && (SwiftText.Count(w.Text) <= 2 || LooksGarbled(w.Text));
                var above = items.Where(i => i.Kind == Kind.Word && i.Y1 < lab.Y0 - 1 && i.X1 > rx0 - 10 && i.X0 < rx0 + 240 && !IsScrawl(i)).ToList();
                double top = Math.Max((above.Count > 0 ? above.Max(i => i.Y1) : lab.Y0 - 48) + 1, lab.Y0 - 48);
                var region = new Rect(rx0 - 8, top, 250, Math.Max(0, lab.Y0 - 2 - top));
                if (!(region.H > 8)) continue;
                var ruleYs = p.Rules.Select(r => r.Y).ToList();
                if (InkFractionExcludingRules(g, region, ruleYs) > 0.012)
                {
                    items.RemoveAll(i => IsScrawl(i) && i.Y0 >= top - 1);
                    var note = new Item(Kind.Note, "Signed on executed original", rx0, rx0 + 150, lab.Y0 - 14, lab.Y0 - 3);
                    items.Add(note);
                    report.SignaturePlaceholders += 1;
                    report.LeftOutMarks += 1;
                }
            }
        }

        SwiftSort.Sort(items, (a, b) => a.Cy < b.Cy);
        var rows = new List<Row>();
        foreach (var it in items)
        {
            if (rows.Count > 0)
            {
                var r = rows[^1];
                double rh = r.H;
                double tol = Math.Max(rh, it.Kind == Kind.Word ? it.H : rh) * 0.55;
                double ry0 = r.Y0, ry1 = r.Y1;
                bool inBand = it.Cy > ry0 && it.Cy < ry1;
                if (Math.Abs((ry0 + ry1) / 2 - it.Cy) < tol || inBand || (it.Kind == Kind.Blank && it.Y1 > ry0 && it.Y1 < ry1 + rh * 0.6))
                {
                    r.Items.Add(it); continue;
                }
            }
            rows.Add(new Row(new List<Item> { it }));
        }
        foreach (var r in rows) SwiftSort.Sort(r.Items, (a, b) => a.X0 < b.X0);
        return rows;
    }

    public readonly record struct Geo(double Left, double Right, double Top, double BodyH, double BaseSize, string Font);

    public static Geo Geometry(List<PageData> pages, List<List<Row>> rows)
    {
        var lefts = new List<double>(); var rights = new List<double>(); var tops = new List<double>(); var hs = new List<double>();
        var full = new List<(double, double)>();   // (left, right) of pages that are mostly running text
        foreach (var pr in rows)
        {
            var textRows = pr.Where(r => r.Words.Count > 0).ToList();
            if (textRows.Count == 0) continue;
            var xs = SwiftSort.Sorted(textRows.Select(r => r.X0)); var xe = SwiftSort.Sorted(textRows.Select(r => r.X1));
            lefts.Add(xs[xs.Count / 25]); rights.Add(xe[(xe.Count * 9) / 10]);
            if (textRows.Count >= 15) full.Add((xs[xs.Count / 25], xe[(xe.Count * 9) / 10]));
            tops.Add(textRows[0].Y0);
            foreach (var r in textRows) foreach (var w in r.Words) if (SwiftText.Count(w.Text) >= 3) hs.Add(w.H);
        }
        static double Med(List<double> a, double d) => a.Count == 0 ? d : SwiftSort.Sorted(a)[a.Count / 2];
        double bodyH = Med(hs, 13);
        // OCR / PDF word boxes run about 1.12× the type size for mixed-case text.
        double raw = bodyH / 1.12;
        double size = Math.Max(8, Math.Min(14, Math.Floor(raw * 2) / 2));
        // The text column comes from the pages that are mostly running text (exhibit pages with a
        // few short lines would narrow it and make Word wrap more than the PDF did).
        var ls = full.Count == 0 ? lefts : full.Select(f => f.Item1).ToList();
        var ws = full.Count == 0 ? lefts.Zip(rights, (l, r) => r - l).ToList() : full.Select(f => f.Item2 - f.Item1).ToList();
        double left = Math.Max(36, Math.Min(110, Med(ls, 72) - 2));
        return new Geo(left, left + Med(ws, 468) + 10, Med(tops, 72) - 4, bodyH, size, "Times New Roman");
    }

    static readonly Regex MarkerRx = new(@"^(\(?([0-9]{1,2}|[A-Za-z]|[ivxIVX]{1,4})[.)])$", RegexOptions.CultureInvariant);

    public static string? Refusal(List<List<Row>> rowsByPage, List<PageData> pages)
    {
        int tablePages = 0, columnPages = 0, considered = 0;
        for (int pi = 0; pi < rowsByPage.Count; pi++)
        {
            var rows = rowsByPage[pi];
            var textRows = rows.Where(r => r.Words.Count >= 1).ToList();
            if (!(textRows.Count >= 8)) continue;
            considered += 1;
            double W = pages[pi].Width;
            int tabular = 0, split = 0;
            foreach (var r in textRows)
            {
                var segs = WordSegments(r);
                if (segs.Count >= 3) tabular += 1;
                if (segs.Count == 2)
                {
                    var a = segs[0]; var b = segs[^1];
                    if (a.Item2 < W * 0.5 && b.Item1 > W * 0.5 && a.Item2 - a.Item1 > W * 0.22 && b.Item2 - b.Item1 > W * 0.22) split += 1;
                }
            }
            if (DebugBoxes)
            {
                Console.WriteLine($"refusal p{pi + 1}: rows {textRows.Count} tabular {tabular} split {split}");
                foreach (var r in textRows.Take(5))
                    Console.WriteLine($"   row y {(int)r.Y0}-{(int)r.Y1}: " + string.Join(" ", r.Words.Select(w => $"{w.Text}@{(int)w.X0}-{(int)w.X1}")));
            }
            if ((double)tabular / textRows.Count > 0.45) tablePages += 1;
            if ((double)split / textRows.Count > 0.5) columnPages += 1;
        }
        if (!(considered > 0)) return null;
        if ((double)tablePages / considered >= 0.5)
            return "Most of this PDF is laid out as a table. In Word it would come out as loose lines that no longer line up, so Jack won’t make it. Copy Text gives you every word in reading order.";
        if ((double)columnPages / considered >= 0.5)
            return "This PDF is set in columns. Word would run the columns into each other, so Jack won’t make it. Copy Text gives you every word in reading order.";
        return null;
    }

    /// Runs of WORDS separated by gaps wider than ~3 spaces (rules, boxes and blanks ignored).
    public static List<(double, double)> WordSegments(Row r)
    {
        var segs = new List<(double, double)>();
        double gapMax = Math.Max(10, r.H * 1.2);
        foreach (var it in r.Words)
        {
            if (segs.Count > 0 && it.X0 - segs[^1].Item2 < gapMax) { var last = segs[^1]; last.Item2 = Math.Max(last.Item2, it.X1); segs[^1] = last; }
            else segs.Add((it.X0, it.X1));
        }
        return segs;
    }

    /// Runs of items separated by gaps wider than ~3 spaces.
    public static List<(double, double)> SegmentsOf(Row r)
    {
        var segs = new List<(double, double)>();
        double gapMax = Math.Max(10, r.H * 1.2);
        bool skipMarker = IsMarker(r);
        for (int k = 0; k < r.Items.Count; k++)
        {
            var it = r.Items[k];
            if (k == 0 && skipMarker) continue;
            var prev = k > 0 ? r.Items[k - 1] : null;
            bool bridged = prev != null && (prev.Kind == Kind.Blank || it.Kind == Kind.Blank || (prev.Underline && it.Underline));
            if (segs.Count > 0 && (it.X0 - segs[^1].Item2 < gapMax || bridged))
            {
                var last = segs[^1]; last.Item2 = Math.Max(last.Item2, it.X1); segs[^1] = last;
            }
            else segs.Add((it.X0, it.X1));
        }
        return segs;
    }

    public static List<DocxParagraph> Paragraphs(List<List<Row>> rowsByPage, List<PageData> pages, Geo geo, double topY,
                                                 Options options, Report report, List<string> written)
    {
        var @out = new List<DocxParagraph>();
        double maxBefore = options.MatchPages ? pages[0].Height * 0.6 : 30;
        var debugPage = Environment.GetEnvironmentVariable("JACK_WORD_DEBUG_PAGE");

        for (int pi = 0; pi < rowsByPage.Count; pi++)
        {
            var rows = rowsByPage[pi];
            if (rows.Count == 0)
            {
                if (options.MatchPages) @out.Add(new DocxParagraph { PageBreakBefore = pi > 0 });
                continue;
            }
            // Scans sit a little differently on every page: indents are measured from THIS page's
            // own text edge, then laid on the document's margin.
            var textRows = rows.Where(r => r.Words.Count > 0).ToList();
            var xs = SwiftSort.Sorted(textRows.Select(r => r.X0)); var xe = SwiftSort.Sorted(textRows.Select(r => r.X1));
            double L = xs.Count == 0 ? geo.Left : xs[xs.Count / 25];
            double R = xe.Count == 0 ? geo.Right : xe[(xe.Count * 9) / 10] + 6;
            double W = Math.Max(100, R - L);
            double lineH = Math.Max(6, Median(rows.Select(r => r.H).ToList()));
            // Typical baseline-to-baseline pitch on this page → the "normal" gap between rows.
            var pitches = new List<double>();
            for (int k = 1; k < Math.Max(1, rows.Count); k++)
            {
                double d = rows[k].Y0 - rows[k - 1].Y0;
                if (d > 0 && d < lineH * 2.2) pitches.Add(d);
            }
            double normalGap = Math.Max(0, Median(pitches) - lineH);

            foreach (var r in rows)
            {
                r.Segments = SegmentsOf(r).Count;
                double rx0 = r.X0, rx1 = r.X1;
                double mid = (rx0 + rx1) / 2;
                // Centered = clear, roughly equal white space on BOTH sides (an indented full line is not).
                double lg = rx0 - L, rg = R - rx1;
                r.Centered = r.Segments == 1 && Math.Abs(mid - (L + R) / 2) < W * 0.06 && Math.Abs(lg - rg) < W * 0.08
                    && lg > W * 0.12 && rg > W * 0.1 && (rx1 - rx0) < W * 0.75;
            }

            var groups = new List<List<Row>>();
            var markers = new List<bool>();
            for (int k = 0; k < rows.Count; k++)
            {
                var r = rows[k];
                bool marker = IsMarker(r);
                if (k > 0 && groups.Count > 0)
                {
                    var g = groups[^1];
                    var P = rows[k - 1];
                    double gap = r.Y0 - P.Y1;
                    bool pFull = P.X1 > R - W * 0.13;
                    double firstX = g[0].X0;
                    double textX = markers[^1] && g[0].Items.Count > 1 ? g[0].Items[1].X0 : firstX;
                    bool cont = !marker && !r.Centered && !P.Centered && r.Segments == 1 && P.Segments <= 1
                        && pFull && gap < normalGap + lineH * 0.55
                        && r.X0 > L - 6 && r.X0 < textX + lineH * 0.9
                        && !r.Items.Any(i => i.Kind == Kind.Checkbox);
                    if (debugPage != null && int.TryParse(debugPage, out var dp) && dp == pi + 1)
                    {
                        var t = string.Join(" ", r.Words.Take(4).Select(w => w.Text));
                        report.Debug.Add(F("row '{0}' x0 {1:F0} x1 {2:F0} | L {3:F0} R {4:F0} textX {5:F0} | gap {6:F1} norm {7:F1} lineH {8:F1} | pFull {9} seg {10}/{11} cent {12}/{13} marker {14} → {15}",
                            t, r.X0, r.X1, L, R, textX, gap, normalGap, lineH, pFull ? 1 : 0, r.Segments, P.Segments, r.Centered ? 1 : 0, P.Centered ? 1 : 0, marker ? 1 : 0, cont ? "join" : "NEW"));
                    }
                    if (cont) { g.Add(r); continue; }
                }
                groups.Add(new List<Row> { r }); markers.Add(marker);
            }

            double? prevBottom = null;
            for (int gi = 0; gi < groups.Count; gi++)
            {
                var g = groups[gi];
                var para = new DocxParagraph();
                var first = g[0];
                double gap = prevBottom is double pb ? first.Y0 - pb : first.Y0 - topY;
                para.SpaceBefore = Math.Max(0, Math.Min(gi == 0 ? maxBefore : 24, gap - normalGap));
                if (para.SpaceBefore < 2) para.SpaceBefore = 0;
                if (gi == 0) para.PageBreakBefore = options.MatchPages && pi > 0;
                prevBottom = g[^1].Y1;

                if (first.Centered && g.Count == 1)
                {
                    para.Align = DocxAlign.Center;
                }
                else if (markers[gi] && first.Items.Count > 1)
                {
                    double mx = first.Items[0].X0, tx = first.Items[1].X0;
                    para.LeftIndent = Math.Max(0, tx - L);
                    para.FirstLine = -(tx - mx);
                    if (para.LeftIndent + para.FirstLine < 0) para.FirstLine = -para.LeftIndent;
                    para.TabStops.Add(para.LeftIndent);
                }
                else if (g.Count >= 2)
                {
                    double cont = Median(g.Skip(1).Select(r => r.X0).ToList());
                    para.LeftIndent = Math.Max(0, cont - L);
                    double fl = first.X0 - cont;
                    para.FirstLine = Math.Abs(fl) < 4 ? 0 : Math.Max(-para.LeftIndent, fl);
                }
                else
                {
                    para.LeftIndent = Math.Max(0, first.X0 - L);
                }
                if (para.LeftIndent < 3) para.LeftIndent = 0;

                // Size: only whole paragraphs set clearly larger or smaller than the body.
                double ph = Median(g.SelectMany(r => r.Words).Where(w => SwiftText.Count(w.Text) >= 3).Select(w => w.H).ToList());
                double? paraSize = null;
                if (ph > 0)
                {
                    double ratio = ph / geo.BodyH;
                    if (ratio > 1.3 || (ratio < 0.66 && g.SelectMany(r => r.Words).Count() >= 4))
                        paraSize = Math.Max(6, Math.Min(36, Math.Round(geo.BaseSize * ratio * 2, MidpointRounding.AwayFromZero) / 2));
                }

                // Runs.
                var runs = new List<DocxRun>();
                Item? lastWasWord = null;
                for (int ri = 0; ri < g.Count; ri++)
                {
                    var r = g[ri];
                    for (int k = 0; k < r.Items.Count; k++)
                    {
                        var it = r.Items[k];
                        DocxRun? sep = null;
                        if (k == 0 && ri > 0)
                        {
                            if (lastWasWord != null && lastWasWord.Text.EndsWith("-", StringComparison.Ordinal)) sep = null;
                            else sep = DocxRun.TextRun(" ", new DocxRunStyle());
                        }
                        else if (k > 0)
                        {
                            var prev = r.Items[k - 1];
                            double gapX = it.X0 - prev.X1;
                            if (k == 1 && markers[gi] && ri == 0 && para.TabStops.Count == 1)
                            {
                                sep = DocxRun.Tab(new DocxRunStyle());
                            }
                            else if (gapX > Math.Max(10, r.H * 1.2))
                            {
                                sep = DocxRun.Tab(new DocxRunStyle());
                                para.TabStops.Add(Math.Max(0, it.X0 - L));
                            }
                            else if (prev.Kind == Kind.Word || it.Kind == Kind.Word || prev.Kind == Kind.Checkbox)
                            {
                                var st = new DocxRunStyle { Underline = prev.Underline && it.Underline, Bold = prev.Bold && it.Bold };
                                sep = DocxRun.TextRun(" ", st);
                            }
                        }
                        if (sep != null) runs.Add(sep);
                        switch (it.Kind)
                        {
                            case Kind.Word:
                                {
                                    var st = new DocxRunStyle { Bold = it.Bold, Underline = it.Underline, Highlight = it.Uncertain && options.MarkUncertain };
                                    if (paraSize is double ps) st.Size = ps;
                                    runs.Add(DocxRun.TextRun(it.Text, st));
                                    written.AddRange(Tokens(it.Text));
                                    report.Words += 1;
                                    if (it.Uncertain) report.UncertainWords += 1; else report.AgreedWords += 1;
                                    lastWasWord = it;
                                    break;
                                }
                            case Kind.Checkbox:
                                runs.Add(DocxRun.Checkbox(it.Checked));
                                break;
                            case Kind.Blank:
                                runs.Add(DocxRun.Blank(it.X1 - it.X0, new DocxRunStyle { Size = geo.BaseSize }));
                                break;
                            case Kind.Note:
                                runs.Add(DocxRun.TextRun(it.Text, new DocxRunStyle { Italic = true, Size = Math.Max(7, geo.BaseSize - 2), Color = "595959" }));
                                written.AddRange(Tokens(it.Text));
                                break;
                        }
                    }
                }
                para.Runs = Coalesce(runs);
                para.TabStops = SwiftSort.Sorted(para.TabStops.Select(t => Math.Round(t * 2, MidpointRounding.AwayFromZero) / 2).Distinct());
                if (markers[gi] || g.Count == 1 && first.Words.Count <= 8 && first.Words.All(w => w.Bold || w.Underline))
                    para.KeepWithNext = !markers[gi];
                @out.Add(para);
            }
        }
        return @out;
    }

    public static bool IsMarker(Row r)
    {
        if (!(r.Items.Count >= 2)) return false;
        var f = r.Items[0];
        if (f.Kind != Kind.Word) return false;
        if (!MarkerRx.IsMatch(f.Text)) return false;
        return r.Items[1].X0 - f.X1 > Math.Max(4, r.H * 0.45);
    }

    public static List<DocxRun> Coalesce(List<DocxRun> runs)
    {
        var @out = new List<DocxRun>();
        foreach (var r in runs)
        {
            if (r.Type == DocxRunType.Text && @out.Count > 0 && @out[^1].Type == DocxRunType.Text && r.Style.Equals(@out[^1].Style))
                @out[^1] = DocxRun.TextRun(@out[^1].Text + r.Text, @out[^1].Style);
            else
                @out.Add(r);
        }
        return @out;
    }

    // MARK: - 5. Verification helpers

    /// The words of the written .docx body, as Word would show them (paragraph text, tabs as
    /// separators). The Mac reopens the file through Cocoa's Word importer; here the package is
    /// reopened and document.xml parsed, which reads the same text runs.
    public static List<string>? ReadBack(string path)
    {
        try
        {
            using var zip = ZipFile.OpenRead(path);
            var entry = zip.GetEntry("word/document.xml");
            if (entry == null) return null;
            using var s = entry.Open();
            using var xr = XmlReader.Create(s, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit });
            const string w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
            var sb = new StringBuilder();
            bool positioned = false;   // ReadElementContentAsString already moved to the next node
            while (positioned || xr.Read())
            {
                positioned = false;
                if (xr.NodeType == XmlNodeType.Element && xr.NamespaceURI == w)
                {
                    if (xr.LocalName == "t" && !xr.IsEmptyElement) { sb.Append(xr.ReadElementContentAsString()); positioned = true; }
                    // <w:tab/> in a run is a tab character; <w:tab w:pos=…> inside <w:tabs> is a tab stop.
                    else if (xr.LocalName == "tab" && !xr.HasAttributes) sb.Append('\t');
                }
                else if (xr.NodeType == XmlNodeType.EndElement && xr.NamespaceURI == w && xr.LocalName == "p") sb.Append('\n');
            }
            return Tokens(sb.ToString());
        }
        catch (Exception) { return null; }
    }

    /// Fraction of `a` found in `b` in the same order (greedy, windowed — a sanity check, not a diff).
    public static double InOrderRatio(List<string> a, List<string> b)
    {
        if (a.Count == 0) return 1;
        int j = 0, hit = 0;
        foreach (var t in a)
        {
            int k = j;
            int limit = Math.Min(b.Count, j + 60);
            while (k < limit && b[k] != t) k += 1;
            if (k < limit) { hit += 1; j = k + 1; }
        }
        return (double)hit / a.Count;
    }

    /// Indices of `a` that belong to a longest common subsequence with `b`.
    public static HashSet<int> LcsMatches(List<string> a, List<string> b)
    {
        int n = a.Count, m = b.Count;
        if (!(n > 0 && m > 0)) return new HashSet<int>();
        var dp = new ushort[n + 1][];
        for (int i = 0; i <= n; i++) dp[i] = new ushort[m + 1];
        for (int i = n - 1; i >= 0; i--)
            for (int j = m - 1; j >= 0; j--)
                dp[i][j] = a[i] == b[j] ? unchecked((ushort)(dp[i + 1][j + 1] + 1)) : Math.Max(dp[i + 1][j], dp[i][j + 1]);
        var @out = new HashSet<int>();
        int ii = 0, jj = 0;
        while (ii < n && jj < m)
        {
            if (a[ii] == b[jj]) { @out.Add(ii); ii += 1; jj += 1; }
            else if (dp[ii + 1][jj] >= dp[ii][jj + 1]) ii += 1; else jj += 1;
        }
        return @out;
    }

    /// Lowercased letters/marks/numbers only, ASCII digits as '#'.
    public static string Norm(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var r in SwiftText.Lower(s).EnumerateRunes())
        {
            if (!SwiftText.IsAlphanumeric(r)) continue;
            if (r.Value >= '0' && r.Value <= '9') sb.Append('#'); else sb.Append(r.ToString());
        }
        return sb.ToString();
    }

    public static List<string> Tokens(string s)
    {
        var @out = new List<string>();
        var sb = new StringBuilder();
        foreach (var r in SwiftText.Lower(s).EnumerateRunes())
        {
            if (SwiftText.IsAlphanumeric(r)) sb.Append(r.ToString());
            else if (sb.Length > 0) { @out.Add(sb.ToString()); sb.Clear(); }
        }
        if (sb.Length > 0) @out.Add(sb.ToString());
        return @out;
    }

    /// Characters a printed document never uses inside a word: the signature of a misread.
    public static bool LooksGarbled(string w)
    {
        if (w.Contains('�')) return true;
        var inner = SwiftText.TrimScalars(w, ".,;:!?\"'’“”()[]");
        if (!(SwiftText.Count(inner) >= 2)) return false;
        const string odd = "[]{}|\\~^`<>";
        foreach (var r in inner.EnumerateRunes()) if (r.Value < 0x10000 && odd.Contains((char)r.Value)) return true;
        int letters = 0, digits = 0;
        foreach (var r in inner.EnumerateRunes())
        {
            if (SwiftText.IsLetter(r)) letters++;
            if (Rune.GetUnicodeCategory(r) == UnicodeCategory.DecimalDigitNumber) digits++;
        }
        // "c]:lildren", "Fnmili" — letters broken by stray punctuation in the middle.
        var chars = SwiftText.Characters(inner);
        if (letters >= 3 && chars.Skip(1).Take(Math.Max(0, chars.Count - 2)).Any(c => c == ":" || c == ";")) return true;
        if (letters >= 2 && digits >= 1 && letters + digits == chars.Count && digits < 3 && !inner.StartsWith("$", StringComparison.Ordinal))
        {
            // Mixed like "l0ss" — but allow codes like "W9", "2CFR", "90640"-style handled above.
            return chars.Count <= 6 ? false : true;
        }
        return false;
    }

    public static double Median(List<double> a) => a.Count == 0 ? 0 : SwiftSort.Sorted(a)[a.Count / 2];

    internal static string F(string format, params object[] args) => string.Format(CultureInfo.InvariantCulture, format, args);
}

/// Swift String / Character / CharacterSet behaviour the engine depends on.
public static class SwiftText
{
    /// `String.count`: extended grapheme clusters (Swift's Character).
    public static int Count(string s) => s.Length == 0 ? 0 : new StringInfo(s).LengthInTextElements;

    /// The string's Characters (extended grapheme clusters).
    public static List<string> Characters(string s)
    {
        var list = new List<string>();
        var e = StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext()) list.Add((string)e.Current);
        return list;
    }

    /// `String.lowercased()`. (.NET uses simple case mapping; Swift full mapping differs only for a
    /// handful of characters such as U+0130.)
    public static string Lower(string s) => s.ToLowerInvariant();

    /// CharacterSet.alphanumerics: Unicode general categories L*, M*, N*.
    public static bool IsAlphanumeric(Rune r) => Rune.GetUnicodeCategory(r) switch
    {
        UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
            or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter
            or UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark
            or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber => true,
        _ => false,
    };

    /// CharacterSet.letters: L* and M*.
    public static bool IsLetter(Rune r) => Rune.GetUnicodeCategory(r) switch
    {
        UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
            or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter
            or UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark => true,
        _ => false,
    };

    /// CharacterSet.whitespaces: Zs and tab.
    public static bool IsWhitespace(Rune r) => r.Value == 9 || Rune.GetUnicodeCategory(r) == UnicodeCategory.SpaceSeparator;

    /// CharacterSet.whitespacesAndNewlines: Zs, tab, U+000A–U+000D, U+0085, U+2028, U+2029.
    public static bool IsWhitespaceOrNewline(Rune r) =>
        IsWhitespace(r) || (r.Value >= 0x0A && r.Value <= 0x0D) || r.Value == 0x85 || r.Value == 0x2028 || r.Value == 0x2029;

    public static string TrimWhitespacesAndNewlines(string s) => TrimWhere(s, IsWhitespaceOrNewline);
    public static string TrimWhitespaces(string s) => TrimWhere(s, IsWhitespace);
    public static string TrimScalars(string s, string set) => TrimWhere(s, r => set.EnumerateRunes().Contains(r));

    static string TrimWhere(string s, Func<Rune, bool> drop)
    {
        var runes = s.EnumerateRunes().ToList();
        int a = 0, b = runes.Count;
        while (a < b && drop(runes[a])) a++;
        while (b > a && drop(runes[b - 1])) b--;
        var sb = new StringBuilder();
        for (int i = a; i < b; i++) sb.Append(runes[i].ToString());
        return sb.ToString();
    }

    /// `components(separatedBy: .whitespacesAndNewlines)` (empty pieces included, as in Swift).
    public static List<string> SplitWhitespacesAndNewlines(string s)
    {
        var parts = new List<string>();
        var sb = new StringBuilder();
        foreach (var r in s.EnumerateRunes())
        {
            if (IsWhitespaceOrNewline(r)) { parts.Add(sb.ToString()); sb.Clear(); }
            else sb.Append(r.ToString());
        }
        parts.Add(sb.ToString());
        return parts;
    }

    /// `Int(String)`: optional sign, ASCII digits only.
    public static int? SwiftInt(string s) =>
        int.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var v) && s.Length > 0 && s.All(c => c == '-' || c == '+' || (c >= '0' && c <= '9')) ? v : null;

    /// Character.isUppercase for the first scalar (Lu).
    public static bool CharIsUppercase(string c) => c.Length > 0 && Rune.IsUpper(c.EnumerateRunes().First());

    /// Character.isLetter for the first scalar (L*).
    public static bool CharIsLetter(string c) => c.Length > 0 && Rune.IsLetter(c.EnumerateRunes().First());
}
