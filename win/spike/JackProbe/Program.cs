// JackProbe — Phase 1 spike for Jack for Windows. Answers, with numbers, on a real Windows box:
//   1. Does PDFium load on this architecture and give words with positions?
//   2. Can PDFium draw pages and write PDFs (image-only "scan", invisible text layer)?
//   3. Do Windows OCR and Tesseract read a scan from .NET 8, and how accurately?
//   4. When the two OCR engines disagree, does that catch the wrong words (the "read twice" signal)?
//   5. Does a searchable copy round-trip the right words, with the original left byte-identical?
// Usage: JackProbe --out <dir> [--tessdata <dir>] [--real <file.pdf>]
// All test content is synthetic. Writes results.json, summary.md and the PDFs it made to <dir>.
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Security.Cryptography;

namespace JackProbe;

record Word(string Text, double L, double B, double R, double T, float Conf = -1);

record Check(string Name, bool Ok, bool Required, string Detail, long Ms);

static class Program
{
    static readonly List<Check> Checks = new();
    static readonly Dictionary<string, object?> Facts = new();

    static async Task<int> Main(string[] args)
    {
        string Arg(string name, string? fallback = null)
        {
            var i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : fallback ?? "";
        }
        var outDir = Path.GetFullPath(Arg("--out", "probe-out"));
        var tessdata = Arg("--tessdata");
        var real = Arg("--real");
        Directory.CreateDirectory(outDir);

        Facts["process_arch"] = RuntimeInformation.ProcessArchitecture.ToString();
        Facts["os_arch"] = RuntimeInformation.OSArchitecture.ToString();
        Facts["os"] = RuntimeInformation.OSDescription;
        Facts["dotnet"] = RuntimeInformation.FrameworkDescription;

        if (!Run("pdfium_load", true, () => { P.FPDF_InitLibrary(); return "pdfium.dll loaded and initialised"; }))
            return Finish(outDir);

        // 1. Synthetic letter written by PDFium (text objects), then read back.
        var fixture = Path.Combine(outDir, "fixture-letter.pdf");
        Run("pdfium_write_text_pdf", true, () => { Fixture.Write(fixture); return $"{new FileInfo(fixture).Length:N0} bytes"; });

        List<Word> truth = new();
        Run("pdfium_extract_words", true, () =>
        {
            var doc = P.Open(fixture);
            var page = P.FPDF_LoadPage(doc, 0);
            truth = Pdf.Words(page);
            P.FPDF_ClosePage(page);
            P.FPDF_CloseDocument(doc);
            var expected = Score.Tokens(string.Join(" ", Fixture.Lines.Select(l => l.Text)));
            var acc = Score.InOrder(expected, truth.Select(w => Score.Norm(w.Text)).ToList());
            Facts["truth_words"] = truth.Count;
            Facts["truth_sample"] = truth.Take(8).Select(w => $"{w.Text} [{w.L:F1},{w.B:F1},{w.R:F1},{w.T:F1}]").ToList();
            if (acc < 0.99) throw new Exception($"extraction matched only {acc:P1} of the written words");
            return $"{truth.Count} words with boxes, {acc:P1} match the text written";
        });

        // 2. Real-world PDF (public government form), if supplied.
        if (File.Exists(real))
        {
            Run("pdfium_real_pdf", false, () =>
            {
                var doc = P.Open(real);
                int pages = P.FPDF_GetPageCount(doc);
                var first = P.FPDF_LoadPage(doc, 0);
                var words = Pdf.Words(first);
                P.FPDF_ClosePage(first);
                var sw = Stopwatch.StartNew();
                for (int i = 0; i < pages; i++)
                {
                    var pg = P.FPDF_LoadPage(doc, i);
                    Pdf.Render(pg, 150);
                    P.FPDF_ClosePage(pg);
                }
                var perPage = sw.ElapsedMilliseconds / Math.Max(1, pages);
                P.FPDF_CloseDocument(doc);
                Facts["real_pdf_sha256"] = Sha(real);
                Facts["real_pdf_first_words"] = string.Join(" ", words.Take(20).Select(w => w.Text));
                Facts["real_pdf_render_ms_per_page_150dpi"] = perPage;
                return $"{pages} pages, {words.Count} words on page 1, {perPage} ms/page to draw at 150 DPI";
            });
        }

        // 3. Make a "scan": draw the letter at 200 DPI, add noise, store as an image-only PDF.
        var scan = Path.Combine(outDir, "fixture-scan.pdf");
        Run("pdfium_write_scan_pdf", true, () =>
        {
            var doc = P.Open(fixture);
            var page = P.FPDF_LoadPage(doc, 0);
            var img = Pdf.Render(page, 200);
            P.FPDF_ClosePage(page);
            P.FPDF_CloseDocument(doc);
            Pdf.AddNoise(img, seed: 42);
            Pdf.WriteImagePdf(img, 612, 792, scan);
            var check = P.Open(scan);
            var cp = P.FPDF_LoadPage(check, 0);
            var leftover = Pdf.Words(cp).Count;
            P.FPDF_ClosePage(cp);
            P.FPDF_CloseDocument(check);
            if (leftover != 0) throw new Exception($"scan still has {leftover} text words");
            return $"{img.W}x{img.H} px image-only page, {new FileInfo(scan).Length:N0} bytes, 0 text words";
        });

        var scanHashBefore = File.Exists(scan) ? Sha(scan) : "";

        // 4. OCR the scan with both engines.
        List<Word>? win = null, tess = null;
        await RunAsync("windows_ocr", false, async () =>
        {
            Facts["windows_ocr_languages"] = string.Join(",", OcrEngine.AvailableRecognizerLanguages.Select(l => l.LanguageTag));
            var engine = OcrEngine.TryCreateFromLanguage(new Windows.Globalization.Language("en-US"))
                         ?? OcrEngine.TryCreateFromUserProfileLanguages()
                         ?? throw new Exception("no Windows OCR engine: no OCR language installed on this machine");
            Facts["windows_ocr_max_dimension"] = OcrEngine.MaxImageDimension;
            var (img, scale, pageH) = RenderScan(scan, 300, (int)OcrEngine.MaxImageDimension);
            var sw = Stopwatch.StartNew();
            using var bmp = SoftwareBitmap.CreateCopyFromBuffer(CryptographicBuffer.CreateFromByteArray(img.Bgra),
                BitmapPixelFormat.Bgra8, img.W, img.H, BitmapAlphaMode.Premultiplied);
            var result = await engine.RecognizeAsync(bmp);
            win = result.Lines.SelectMany(l => l.Words).Select(w => new Word(w.Text,
                w.BoundingRect.X / scale, pageH - (w.BoundingRect.Y + w.BoundingRect.Height) / scale,
                (w.BoundingRect.X + w.BoundingRect.Width) / scale, pageH - w.BoundingRect.Y / scale)).ToList();
            Facts["windows_ocr_ms"] = sw.ElapsedMilliseconds;
            return Score.Describe(win, truth, $"{img.W}x{img.H} px, {sw.ElapsedMilliseconds} ms");
        });

        await RunAsync("tesseract_ocr", false, () =>
        {
            if (!Directory.Exists(tessdata)) throw new Exception("no --tessdata folder given");
            var (img, scale, pageH) = RenderScan(scan, 300, 20000);
            var sw = Stopwatch.StartNew();
            tess = Tess.Read(tessdata, img, scale, pageH);
            Facts["tesseract_ms"] = sw.ElapsedMilliseconds;
            return Task.FromResult(Score.Describe(tess, truth, $"{sw.ElapsedMilliseconds} ms"));
        });

        // 5. Read-twice signal: does Windows OCR vs Tesseract disagreement land on the wrong words?
        if (win != null && tess != null)
        {
            Run("read_twice_signal", false, () =>
            {
                var s = Score.Disagreement(win, tess, truth);
                Facts["read_twice"] = s;
                return s.Summary;
            });
        }

        // 6. Searchable copy: invisible OCR words over the scan, saved as a new file.
        var searchable = Path.Combine(outDir, "fixture-scan (searchable).pdf");
        var source = win ?? tess;
        Run("searchable_write", true, () =>
        {
            if (source == null) throw new Exception("no OCR engine produced words on this machine");
            Pdf.WriteSearchableCopy(scan, searchable, source);
            return $"{source.Count} invisible words from {(win != null ? "Windows OCR" : "Tesseract")}, {new FileInfo(searchable).Length:N0} bytes";
        });
        Run("searchable_roundtrip", true, () =>
        {
            var doc = P.Open(searchable);
            var page = P.FPDF_LoadPage(doc, 0);
            var back = Pdf.Words(page);
            P.FPDF_ClosePage(page);
            P.FPDF_CloseDocument(doc);
            var acc = Score.InOrder(truth.Select(w => Score.Norm(w.Text)).ToList(), back.Select(w => Score.Norm(w.Text)).ToList());
            Facts["searchable_words_back"] = back.Count;
            Facts["searchable_sample"] = string.Join(" ", back.Take(25).Select(w => w.Text));
            if (acc < 0.90) throw new Exception($"only {acc:P1} of the letter's words read back from the searchable copy");
            return $"{back.Count} words read back, {acc:P1} of the letter in order";
        });
        Run("original_untouched", true, () =>
        {
            var after = Sha(scan);
            if (after != scanHashBefore) throw new Exception("the scan changed on disk");
            return $"scan SHA-256 unchanged ({after[..12]}…)";
        });

        return Finish(outDir);
    }

    static (Pdf.Image img, double scale, double pageH) RenderScan(string path, double dpi, int maxDim)
    {
        var doc = P.Open(path);
        var page = P.FPDF_LoadPage(doc, 0);
        double w = P.FPDF_GetPageWidthF(page), h = P.FPDF_GetPageHeightF(page);
        dpi = Math.Min(dpi, maxDim * 72.0 / Math.Max(w, h));
        var img = Pdf.Render(page, dpi);
        P.FPDF_ClosePage(page);
        P.FPDF_CloseDocument(doc);
        return (img, dpi / 72.0, h);
    }

    static bool Run(string name, bool required, Func<string> body)
    {
        var sw = Stopwatch.StartNew();
        try
        {
            var detail = body();
            Checks.Add(new Check(name, true, required, detail, sw.ElapsedMilliseconds));
            Console.WriteLine($"PASS {name}: {detail}");
            return true;
        }
        catch (Exception e)
        {
            var root = e; while (root.InnerException != null) root = root.InnerException;
            var detail = root == e ? $"{e.GetType().Name}: {e.Message}" : $"{e.GetType().Name} -> {root.GetType().Name}: {root.Message}";
            Checks.Add(new Check(name, false, required, detail, sw.ElapsedMilliseconds));
            Console.WriteLine($"FAIL {name}: {detail}");
            return false;
        }
    }

    static async Task RunAsync(string name, bool required, Func<Task<string>> body)
    {
        var sw = Stopwatch.StartNew();
        try
        {
            var detail = await body();
            Checks.Add(new Check(name, true, required, detail, sw.ElapsedMilliseconds));
            Console.WriteLine($"PASS {name}: {detail}");
        }
        catch (Exception e)
        {
            var root = e; while (root.InnerException != null) root = root.InnerException;
            var detail = root == e ? $"{e.GetType().Name}: {e.Message}" : $"{e.GetType().Name} -> {root.GetType().Name}: {root.Message}";
            Checks.Add(new Check(name, false, required, detail, sw.ElapsedMilliseconds));
            Console.WriteLine($"FAIL {name}: {detail}");
        }
    }

    static int Finish(string outDir)
    {
        var json = JsonSerializer.Serialize(new { facts = Facts, checks = Checks }, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(Path.Combine(outDir, "results.json"), json);
        var md = new StringBuilder();
        md.AppendLine($"### JackProbe on {Facts["os_arch"]} OS, {Facts["process_arch"]} process");
        md.AppendLine();
        md.AppendLine("| Check | Result | Required | Detail |");
        md.AppendLine("|---|---|---|---|");
        foreach (var c in Checks)
            md.AppendLine($"| {c.Name} | {(c.Ok ? "PASS" : "FAIL")} | {(c.Required ? "yes" : "no")} | {c.Detail.Replace("|", "/")} |");
        md.AppendLine();
        md.AppendLine("```json");
        md.AppendLine(JsonSerializer.Serialize(Facts, new JsonSerializerOptions { WriteIndented = true }));
        md.AppendLine("```");
        File.WriteAllText(Path.Combine(outDir, "summary.md"), md.ToString());
        var failed = Checks.Count(c => c.Required && !c.Ok);
        Console.WriteLine(failed == 0 ? "ALL REQUIRED CHECKS PASSED" : $"{failed} REQUIRED CHECK(S) FAILED");
        return failed == 0 ? 0 : 1;
    }

    static string Sha(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
}

static class Pdf
{
    public sealed class Image
    {
        public int W, H;
        public byte[] Bgra = Array.Empty<byte>();
    }

    public static List<Word> Words(IntPtr page)
    {
        var tp = P.FPDFText_LoadPage(page);
        int n = P.FPDFText_CountChars(tp);
        var words = new List<Word>();
        var sb = new StringBuilder();
        double l = 0, b = 0, r = 0, t = 0;
        void Flush()
        {
            if (sb.Length > 0) words.Add(new Word(sb.ToString(), l, b, r, t));
            sb.Clear();
        }
        for (int i = 0; i < n; i++)
        {
            uint u = P.FPDFText_GetUnicode(tp, i);
            if (u is ' ' or '\r' or '\n' or '\t' or 0 or 2 or 0xFFFE) { Flush(); continue; }
            P.FPDFText_GetCharBox(tp, i, out var cl, out var cr, out var cb, out var ct);
            if (sb.Length == 0) { l = cl; r = cr; b = cb; t = ct; }
            else { l = Math.Min(l, cl); r = Math.Max(r, cr); b = Math.Min(b, cb); t = Math.Max(t, ct); }
            sb.Append(u <= 0xFFFF ? ((char)u).ToString() : char.ConvertFromUtf32((int)u));
        }
        Flush();
        P.FPDFText_ClosePage(tp);
        return words;
    }

    public static Image Render(IntPtr page, double dpi)
    {
        double s = dpi / 72.0;
        int w = (int)Math.Round(P.FPDF_GetPageWidthF(page) * s), h = (int)Math.Round(P.FPDF_GetPageHeightF(page) * s);
        var bmp = P.FPDFBitmap_Create(w, h, 0);
        if (bmp == IntPtr.Zero) throw new Exception($"could not allocate {w}x{h} bitmap");
        P.FPDFBitmap_FillRect(bmp, 0, 0, w, h, 0xFFFFFFFF);
        P.FPDF_RenderPageBitmap(bmp, page, 0, 0, w, h, 0, P.RenderAnnotations);
        var buf = P.FPDFBitmap_GetBuffer(bmp);
        int stride = P.FPDFBitmap_GetStride(bmp);
        var px = new byte[w * h * 4];
        for (int y = 0; y < h; y++) Marshal.Copy(buf + y * stride, px, y * w * 4, w * 4);
        for (int i = 3; i < px.Length; i += 4) px[i] = 255;
        P.FPDFBitmap_Destroy(bmp);
        return new Image { W = w, H = h, Bgra = px };
    }

    /// Grey it, add sensor noise and a few specks, like a cheap office scanner.
    public static void AddNoise(Image img, int seed)
    {
        var rnd = new Random(seed);
        for (int i = 0; i < img.Bgra.Length; i += 4)
        {
            int g = (img.Bgra[i] * 29 + img.Bgra[i + 1] * 150 + img.Bgra[i + 2] * 77) >> 8;
            g += rnd.Next(-16, 17);
            if (rnd.NextDouble() < 0.0006) g = 40;
            g = Math.Clamp(g, 0, 255);
            img.Bgra[i] = img.Bgra[i + 1] = img.Bgra[i + 2] = (byte)g;
        }
    }

    public static void WriteImagePdf(Image img, double wPt, double hPt, string path)
    {
        var doc = P.FPDF_CreateNewDocument();
        var page = P.FPDFPage_New(doc, 0, wPt, hPt);
        var bmp = P.FPDFBitmap_Create(img.W, img.H, 0);
        var buf = P.FPDFBitmap_GetBuffer(bmp);
        int stride = P.FPDFBitmap_GetStride(bmp);
        for (int y = 0; y < img.H; y++) Marshal.Copy(img.Bgra, y * img.W * 4, buf + y * stride, img.W * 4);
        var obj = P.FPDFPageObj_NewImageObj(doc);
        if (P.FPDFImageObj_SetBitmap(IntPtr.Zero, 0, obj, bmp) == 0) throw new Exception("FPDFImageObj_SetBitmap failed");
        P.FPDFImageObj_SetMatrix(obj, wPt, 0, 0, hPt, 0, 0);
        P.FPDFPage_InsertObject(page, obj);
        if (P.FPDFPage_GenerateContent(page) == 0) throw new Exception("FPDFPage_GenerateContent failed");
        P.Save(doc, path);
        P.FPDFBitmap_Destroy(bmp);
        P.FPDF_ClosePage(page);
        P.FPDF_CloseDocument(doc);
    }

    /// Opens the scan read-only, adds one invisible text object per OCR word sized to its box,
    /// and saves a NEW file. The scan itself is never written.
    public static void WriteSearchableCopy(string scan, string output, List<Word> words)
    {
        var doc = P.Open(scan);
        var page = P.FPDF_LoadPage(doc, 0);
        var font = P.FPDFText_LoadStandardFont(doc, "Helvetica");
        foreach (var w in words)
        {
            double h = Math.Max(1, w.T - w.B);
            var obj = P.FPDFPageObj_CreateTextObj(doc, font, (float)h);
            P.FPDFText_SetText(obj, w.Text);
            P.FPDFTextObj_SetTextRenderMode(obj, P.TextRenderInvisible);
            P.FPDFPageObj_GetBounds(obj, out var l, out _, out var r, out _);
            double natural = r - l;
            // A real space after every word: without it, extractors glue close OCR boxes into one
            // word ("payableon"). The scale above is measured on the word alone, so glyphs still
            // line up with the scan.
            P.FPDFText_SetText(obj, w.Text + " ");
            double sx = natural > 0.01 ? (w.R - w.L) / natural : 1;
            P.FPDFPageObj_Transform(obj, sx, 0, 0, 1, w.L - l * sx, w.B + 0.2 * h);
            P.FPDFPage_InsertObject(page, obj);
        }
        if (P.FPDFPage_GenerateContent(page) == 0) throw new Exception("FPDFPage_GenerateContent failed");
        P.Save(doc, output);
        P.FPDFFont_Close(font);
        P.FPDF_ClosePage(page);
        P.FPDF_CloseDocument(doc);
    }
}

static class Tess
{
    public static List<Word> Read(string tessdata, Pdf.Image img, double scale, double pageH)
    {
        using var engine = new Tesseract.TesseractEngine(tessdata, "eng", Tesseract.EngineMode.LstmOnly);
        engine.SetVariable("user_defined_dpi", ((int)Math.Round(scale * 72)).ToString());
        using var pix = Tesseract.Pix.LoadFromMemory(Bmp24(img));
        using var page = engine.Process(pix, Tesseract.PageSegMode.Auto);
        var words = new List<Word>();
        using var it = page.GetIterator();
        it.Begin();
        do
        {
            if (!it.TryGetBoundingBox(Tesseract.PageIteratorLevel.Word, out var r)) continue;
            var text = it.GetText(Tesseract.PageIteratorLevel.Word)?.Trim();
            if (string.IsNullOrEmpty(text)) continue;
            words.Add(new Word(text, r.X1 / scale, pageH - r.Y2 / scale, r.X2 / scale, pageH - r.Y1 / scale,
                it.GetConfidence(Tesseract.PageIteratorLevel.Word)));
        } while (it.Next(Tesseract.PageIteratorLevel.Word));
        return words;
    }

    static byte[] Bmp24(Pdf.Image img)
    {
        int row = (img.W * 3 + 3) & ~3;
        var data = new byte[54 + row * img.H];
        void I32(int o, int v) => BitConverter.GetBytes(v).CopyTo(data, o);
        data[0] = (byte)'B'; data[1] = (byte)'M';
        I32(2, data.Length); I32(10, 54); I32(14, 40); I32(18, img.W); I32(22, img.H);
        data[26] = 1; data[28] = 24; I32(34, row * img.H);
        for (int y = 0; y < img.H; y++)
        {
            int dst = 54 + (img.H - 1 - y) * row;
            for (int x = 0; x < img.W; x++)
            {
                int s = (y * img.W + x) * 4;
                data[dst + x * 3] = img.Bgra[s];
                data[dst + x * 3 + 1] = img.Bgra[s + 1];
                data[dst + x * 3 + 2] = img.Bgra[s + 2];
            }
        }
        return data;
    }
}

static class Score
{
    public static string Norm(string s) => s.Trim().Trim('.', ',', ';', ':', '!', '?', '(', ')', '"', '\'', '“', '”', '‘', '’').ToLowerInvariant();

    public static List<string> Tokens(string s) => s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Select(Norm).Where(t => t.Length > 0).ToList();

    /// Indexes of b that are part of the longest in-order match with a.
    public static HashSet<int> Matched(List<string> a, List<string> b)
    {
        var dp = new int[a.Count + 1, b.Count + 1];
        for (int i = a.Count - 1; i >= 0; i--)
            for (int j = b.Count - 1; j >= 0; j--)
                dp[i, j] = a[i] == b[j] ? dp[i + 1, j + 1] + 1 : Math.Max(dp[i + 1, j], dp[i, j + 1]);
        var set = new HashSet<int>();
        for (int i = 0, j = 0; i < a.Count && j < b.Count;)
        {
            if (a[i] == b[j]) { set.Add(j); i++; j++; }
            else if (dp[i + 1, j] >= dp[i, j + 1]) i++;
            else j++;
        }
        return set;
    }

    /// Share of the reference words found, in order, in the candidate.
    public static double InOrder(List<string> reference, List<string> candidate) =>
        reference.Count == 0 ? 0 : (double)Matched(reference, candidate).Count / reference.Count;

    public static string Describe(List<Word> got, List<Word> truth, string extra)
    {
        var t = truth.Select(w => Norm(w.Text)).ToList();
        var g = got.Select(w => Norm(w.Text)).ToList();
        var hit = Matched(t, g).Count;
        return $"{got.Count} words; {(double)hit / Math.Max(1, t.Count):P1} of the letter read correctly in order; " +
               $"{got.Count - hit} wrong or extra; {extra}";
    }

    public sealed record DisagreementResult(int WindowsWords, int WrongWords, int Flagged, int WrongAndFlagged, double CaughtShare, double FalseFlagShare, string Summary);

    /// Flags each Windows OCR word that Tesseract does not read the same way at the same spot,
    /// then checks the flags against the known truth.
    public static DisagreementResult Disagreement(List<Word> win, List<Word> tess, List<Word> truth)
    {
        var t = truth.Select(w => Norm(w.Text)).ToList();
        var g = win.Select(w => Norm(w.Text)).ToList();
        var right = Matched(t, g);
        int wrong = 0, flagged = 0, caught = 0;
        for (int i = 0; i < win.Count; i++)
        {
            var w = win[i];
            var best = tess.Select(x => (x, iou: IoU(w, x))).OrderByDescending(p => p.iou).FirstOrDefault();
            bool agree = best.x != null && best.iou > 0.3 && Norm(best.x.Text) == g[i];
            bool isWrong = !right.Contains(i);
            if (isWrong) wrong++;
            if (!agree) flagged++;
            if (isWrong && !agree) caught++;
        }
        double caughtShare = wrong == 0 ? 1 : (double)caught / wrong;
        double falseShare = win.Count == 0 ? 0 : (double)(flagged - caught) / win.Count;
        var summary = $"{wrong} wrong Windows OCR words, {caught} of them flagged by disagreement ({caughtShare:P0}); " +
                      $"{flagged - caught} correct words flagged needlessly ({falseShare:P1} of all words)";
        return new DisagreementResult(win.Count, wrong, flagged, caught, caughtShare, falseShare, summary);
    }

    static double IoU(Word a, Word b)
    {
        double ix = Math.Max(0, Math.Min(a.R, b.R) - Math.Max(a.L, b.L));
        double iy = Math.Max(0, Math.Min(a.T, b.T) - Math.Max(a.B, b.B));
        double inter = ix * iy;
        double union = (a.R - a.L) * (a.T - a.B) + (b.R - b.L) * (b.T - b.B) - inter;
        return union <= 0 ? 0 : inter / union;
    }
}

static class Fixture
{
    public record Line(string Text, string Font, float Size, double X, double Y);

    // Synthetic office letter: headings, dates, money, numbered items, a reference number.
    public static readonly List<Line> Lines = Build();

    static List<Line> Build()
    {
        var l = new List<Line>();
        double y = 730;
        void Add(string text, string font = "Times-Roman", float size = 11, double x = 72, double lead = 15)
        {
            l.Add(new Line(text, font, size, x, y));
            y -= lead;
        }
        Add("Harbor Lane Property Services", "Helvetica-Bold", 15, lead: 20);
        Add("1200 Example Avenue, Suite 400, Springfield", "Helvetica", 9, lead: 30);
        Add("November 11, 2026", lead: 22);
        Add("Re: Service Agreement No. SA-2026-0417", "Times-Bold", 11, lead: 22);
        Add("Dear Ms. Alvarez,", lead: 20);
        Add("Thank you for renewing the maintenance agreement for the building at 85 Orchard Street.");
        Add("This letter confirms the terms we discussed on October 28 and the monthly fee of");
        Add("$1,250.00, payable on the first business day of each month beginning December 1.", lead: 20);
        Add("The agreement covers the following services:", lead: 18);
        Add("1. Quarterly inspection of the roof, gutters and drainage.", x: 90);
        Add("2. Repair of common-area lighting within two business days.", x: 90);
        Add("3. Annual testing of the fire alarm panel and emergency exits.", x: 90);
        Add("4. Snow removal from walkways when accumulation exceeds 2 inches.", x: 90, lead: 20);
        Add("Either party may end the agreement with 30 days written notice. Work requested");
        Add("outside this scope will be quoted separately and will not begin without your written");
        Add("approval. Invoices are due within 15 days of receipt.", lead: 20);
        Add("Please sign and return the enclosed copy by November 25, 2026. If you have any");
        Add("questions, call our office at 555-0142 and ask for the service coordinator.", lead: 26);
        Add("Sincerely,", lead: 40);
        Add("Jordan Whitfield");
        Add("Operations Manager");
        return l;
    }

    public static void Write(string path)
    {
        var doc = P.FPDF_CreateNewDocument();
        var page = P.FPDFPage_New(doc, 0, 612, 792);
        var fonts = new Dictionary<string, IntPtr>();
        foreach (var line in Lines)
        {
            if (!fonts.TryGetValue(line.Font, out var font))
                fonts[line.Font] = font = P.FPDFText_LoadStandardFont(doc, line.Font);
            var obj = P.FPDFPageObj_CreateTextObj(doc, font, line.Size);
            if (P.FPDFText_SetText(obj, line.Text) == 0) throw new Exception("FPDFText_SetText failed");
            P.FPDFPageObj_Transform(obj, 1, 0, 0, 1, line.X, line.Y);
            P.FPDFPage_InsertObject(page, obj);
        }
        if (P.FPDFPage_GenerateContent(page) == 0) throw new Exception("FPDFPage_GenerateContent failed");
        P.Save(doc, path);
        foreach (var f in fonts.Values) P.FPDFFont_Close(f);
        P.FPDF_ClosePage(page);
        P.FPDF_CloseDocument(doc);
    }
}
