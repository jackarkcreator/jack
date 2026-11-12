// Make Searchable on Windows: OCR every page that has no text, then save a NEW PDF with an
// invisible text layer at the words' positions, so search, select and copy work. The Windows
// counterpart of Sources/OCREngine.swift (makeSearchable).
//
// Same as the Mac:
//   - only pages whose own text is empty (after trimming) are recognized; a page with any text
//     passes through untouched, so running it twice never stacks a second layer;
//   - the page itself is not redrawn: its picture, annotations and form fields stay as they were.
// Different from the Mac, on purpose:
//   - pages are read through the Save as Word reading path (WordExportEngine.Read): Windows OCR,
//     Tesseract filling the words Windows OCR skipped, low-confidence handwriting left out, and a
//     tilted scan straightened before it is read. Word boxes are turned back onto the tilted page,
//     and each word's text runs along the scan's own slope;
//   - the copy goes to "<name> (searchable).pdf" beside the original (never over anything), and is
//     read back before it is kept: every page that got text must give back the words written, in
//     order, or the copy is deleted;
//   - a page with /Rotate is left alone and reported (its rendering path is not proven yet).
//
// The original is opened read-only (twice: once to read, once as the base of the copy) and is
// never written. The copy is first written to a hidden temporary file in the same folder and only
// renamed into place once it checks out.
using Jack.Core.Windows;
using Jack.Core.Word;

namespace Jack.Core.Searchable;

public static class SearchableEngine
{
    public enum ErrorKind { NothingToDo, NoText, Exists, WriteFailed, VerifyFailed, Cancelled }

    public sealed class SearchableException : Exception
    {
        public readonly ErrorKind Kind;
        public SearchableException(ErrorKind kind, string message) : base(message) { Kind = kind; }
    }

    public sealed class Report
    {
        public int Pages;
        public readonly List<int> Recognized = new();                    // pages that got a text layer
        public readonly List<(int Page, string Why)> LeftAlone = new();  // pages passed through, and why
        public int Words;
        public double Readback;
        public readonly List<string> Debug = new();

        public string Summary =>
            $"{Pages} page(s): {Recognized.Count} made searchable, {LeftAlone.Count} left as they were · {Words} words" +
            WordExportEngine.F(" · read-back {0:F1}%", Readback * 100);
    }

    /// Where the copy lands: "<name> (searchable).pdf" beside the original, never clobbering anything.
    public static string OutputPath(string source)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(source)) ?? ".";
        var b = Path.GetFileNameWithoutExtension(source);
        var candidate = Path.Combine(dir, b + " (searchable).pdf");
        for (int n = 2; File.Exists(candidate); n++) candidate = Path.Combine(dir, $"{b} (searchable {n}).pdf");
        return candidate;
    }

    /// Every page's text as PDFium extracts it: what a viewer's search and copy see.
    public static List<string> PageTexts(string path) => Pdfium.PageTexts(path);

    /// One word to write: text and box in the page image's points (top-left origin), as read.
    sealed record PlacedWord(string Text, double X0, double X1, double Y0, double Y1);

    sealed record PagePlan(int Index, double Deskew, double ImageW, double ImageH, List<PlacedWord> Words);

    /// Write a searchable copy of `input` to `output`. Throws SearchableException; on any throw
    /// nothing is left at `output`.
    public static Report Make(string input, string output, string? tessdata,
                              Action<int, int>? progress = null, Func<bool>? cancelled = null)
    {
        input = Path.GetFullPath(input);
        output = Path.GetFullPath(output);
        if (string.Equals(input, output, StringComparison.OrdinalIgnoreCase))
            throw new SearchableException(ErrorKind.Exists, "The searchable copy can't replace the original.");
        if (File.Exists(output) || Directory.Exists(output))
            throw new SearchableException(ErrorKind.Exists, $"{Path.GetFileName(output)} already exists; Jack never overwrites a file.");

        var report = new Report();
        var plans = new List<PagePlan>();

        // 1. Read: only pages with no text of their own.
        using (var src = new WindowsPageSource(input, tessdata))
        {
            report.Pages = src.PageCount;
            if (src.PageCount <= 0) throw new SearchableException(ErrorKind.NoText, "This PDF has no pages.");
            var wordReport = new WordExportEngine.Report { Pages = src.PageCount };
            for (int i = 0; i < src.PageCount; i++)
            {
                progress?.Invoke(i, src.PageCount);
                if (cancelled?.Invoke() == true) throw new SearchableException(ErrorKind.Cancelled, "Stopped. Nothing was saved.");
                var info = src.Page(i);
                if (SwiftText.TrimWhitespacesAndNewlines(info.TextLayer).Length > 0) { report.LeftAlone.Add((i, "has text")); continue; }
                if (src.Rotation(i) != 0) { report.LeftAlone.Add((i, "rotated page, not supported yet")); continue; }
                var pd = WordExportEngine.Read(src, i, wordReport);
                if (pd.Gray is not GrayImage g) { report.LeftAlone.Add((i, "could not be drawn")); continue; }
                var words = pd.Lines.SelectMany(l => l.Items)
                    .Where(w => w.Kind == WordExportEngine.Kind.Word && w.Text.Trim().Length > 0 && w.X1 > w.X0 && w.Y1 > w.Y0)
                    .Select(w => new PlacedWord(w.Text.Trim(), w.X0, w.X1, w.Y0, w.Y1)).ToList();
                if (words.Count == 0) { report.LeftAlone.Add((i, "no words found")); continue; }
                plans.Add(new PagePlan(i, pd.Deskew, g.W / g.Scale, g.H / g.Scale, words));
                report.Debug.Add(WordExportEngine.F("p{0}: {1} words{2}", i + 1, words.Count,
                    pd.Deskew != 0 ? WordExportEngine.F(", read straightened {0:F2}°", pd.Deskew) : ""));
            }
            foreach (var w in src.Warnings) report.Debug.Add("warning: " + w);
        }
        if (plans.Count == 0)
        {
            bool allText = report.LeftAlone.All(p => p.Why == "has text");
            throw new SearchableException(allText ? ErrorKind.NothingToDo : ErrorKind.NoText,
                allText ? "Every page already has text; nothing to make searchable."
                        : "Jack couldn't find any readable text on the pages without text.");
        }
        if (cancelled?.Invoke() == true) throw new SearchableException(ErrorKind.Cancelled, "Stopped. Nothing was saved.");

        // 2. Write a new file next to the output, then check it, then move it into place.
        var dir = Path.GetDirectoryName(output) ?? ".";
        var temp = Path.Combine(dir, $".{Path.GetFileNameWithoutExtension(output)}.{Guid.NewGuid():N}.tmp");
        var written = new Dictionary<int, List<string>>();
        try
        {
            try { WriteCopy(input, temp, plans, written); }
            catch (Exception e) { throw new SearchableException(ErrorKind.WriteFailed, $"The searchable PDF couldn't be written ({e.Message})."); }

            // 3. Read-back: every page that got text gives back its words, in order.
            List<string> back;
            try { back = Pdfium.PageTexts(temp); }
            catch (Exception e) { throw new SearchableException(ErrorKind.VerifyFailed, $"The searchable PDF didn't reopen ({e.Message}), so Jack didn't keep it."); }
            if (back.Count != report.Pages)
                throw new SearchableException(ErrorKind.VerifyFailed, $"The searchable PDF has {back.Count} pages, not {report.Pages}, so Jack didn't keep it.");
            int total = 0, hit = 0;
            foreach (var (page, words) in written)
            {
                var got = WordExportEngine.Tokens(back[page]);
                total += words.Count;
                hit += WordExportEngine.LcsMatches(words, got).Count;
            }
            report.Words = total;
            report.Readback = total == 0 ? 1 : (double)hit / total;
            if (report.Readback < 0.985)
                throw new SearchableException(ErrorKind.VerifyFailed,
                    WordExportEngine.F("The searchable PDF didn't check out ({0:F0}% of words read back), so Jack didn't keep it.", report.Readback * 100));

            try { File.Move(temp, output, overwrite: false); }
            catch (IOException) when (File.Exists(output))
            { throw new SearchableException(ErrorKind.Exists, $"{Path.GetFileName(output)} appeared while Jack was working; Jack never overwrites a file."); }
            catch (Exception e) { throw new SearchableException(ErrorKind.WriteFailed, $"The searchable PDF couldn't be saved ({e.Message})."); }
        }
        finally
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch { }
        }
        report.Recognized.AddRange(plans.Select(p => p.Index));
        return report;
    }

    /// Opens the original read-only as the base, adds one invisible text object per word on the
    /// planned pages, saves everything as a new file. `written` gets each page's tokens as written.
    static void WriteCopy(string input, string temp, List<PagePlan> plans, Dictionary<int, List<string>> written)
    {
        var doc = Pdfium.Open(input);
        IntPtr font = IntPtr.Zero;
        try
        {
            font = Pdfium.FPDFText_LoadStandardFont(doc, "Helvetica");
            if (font == IntPtr.Zero) throw new InvalidOperationException("PDFium could not load Helvetica");
            foreach (var plan in plans)
            {
                var page = Pdfium.FPDF_LoadPage(doc, plan.Index);
                if (page == IntPtr.Zero) throw new InvalidOperationException($"PDFium could not load page {plan.Index + 1}");
                try
                {
                    var box = MediaBox(page);
                    var tokens = new List<string>();
                    foreach (var w in plan.Words)
                        if (AddInvisibleWord(doc, font, page, w, plan, box)) tokens.AddRange(WordExportEngine.Tokens(w.Text));
                    if (Pdfium.FPDFPage_GenerateContent(page) == 0) throw new InvalidOperationException($"PDFium could not write page {plan.Index + 1}");
                    written[plan.Index] = tokens;
                }
                finally { Pdfium.FPDF_ClosePage(page); }
            }
            Pdfium.SaveAsNew(doc, temp);
        }
        finally
        {
            if (font != IntPtr.Zero) Pdfium.FPDFFont_Close(font);
            Pdfium.FPDF_CloseDocument(doc);
        }
    }

    static (double X, double Y, double W, double H) MediaBox(IntPtr page)
    {
        if (Pdfium.FPDFPage_GetMediaBox(page, out var l, out var b, out var r, out var t) != 0 && r > l && t > b)
            return (l, b, r - l, t - b);
        return (0, 0, Pdfium.FPDF_GetPageWidthF(page), Pdfium.FPDF_GetPageHeightF(page));
    }

    /// One word as invisible text (render mode 3), its glyphs stretched to the word's width and
    /// its baseline 20% of the box height above the box bottom (the spike's proven placement).
    /// 🧨 The trailing space is real text: without it extractors glue neighbouring words together
    /// ("payableon"); the stretch is measured on the word alone so the glyphs still cover the word.
    static bool AddInvisibleWord(IntPtr doc, IntPtr font, IntPtr page, PlacedWord w, PagePlan plan, (double X, double Y, double W, double H) box)
    {
        double h = Math.Max(1, w.Y1 - w.Y0);
        var obj = Pdfium.FPDFPageObj_CreateTextObj(doc, font, (float)h);
        if (obj == IntPtr.Zero) return false;
        if (Pdfium.FPDFText_SetText(obj, w.Text) == 0 ||
            Pdfium.FPDFPageObj_GetBounds(obj, out var l, out _, out var r, out _) == 0 || !(r - l > 0.01))
        {
            Pdfium.FPDFPageObj_Destroy(obj);
            return false;
        }
        double sx = (w.X1 - w.X0) / (r - l);
        Pdfium.FPDFText_SetText(obj, w.Text + " ");
        Pdfium.FPDFTextObj_SetTextRenderMode(obj, Pdfium.TextRenderInvisible);
        // Stretch about the text origin, then turn by the scan's tilt and move the origin to the
        // word's baseline start on the page as it really is (the image was read straightened).
        Pdfium.FPDFPageObj_Transform(obj, sx, 0, 0, 1, -l * sx, 0);
        var (px, py) = ToPdf(plan, box, w.X0, w.Y1 - 0.2 * h);
        double phi = -plan.Deskew * Math.PI / 180, c = Math.Cos(phi), s = Math.Sin(phi);
        Pdfium.FPDFPageObj_Transform(obj, c, s, -s, c, px, py);
        Pdfium.FPDFPage_InsertObject(page, obj);
        return true;
    }

    /// A point in the page image as read (points, top-left origin, possibly straightened by
    /// `plan.Deskew` degrees counter-clockwise about the image centre, as Imaging.Rotate does) →
    /// PDF user space on the original page (bottom-left origin, media box offset).
    static (double X, double Y) ToPdf(PagePlan plan, (double X, double Y, double W, double H) box, double x, double y)
    {
        if (plan.Deskew != 0)
        {
            // y-up about the centre: straight = R(θ)·original, so original = R(−θ)·straight.
            double cx = plan.ImageW / 2, cy = plan.ImageH / 2;
            double th = plan.Deskew * Math.PI / 180, c = Math.Cos(th), s = Math.Sin(th);
            double u = x - cx, v = cy - y;
            double iu = c * u + s * v, iv = -s * u + c * v;
            x = cx + iu; y = cy - iv;
        }
        return (box.X + x, box.Y + box.H - y);
    }
}
