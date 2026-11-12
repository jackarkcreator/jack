// Real pages on Windows: PDFium for the page, its text layer, the scan test and rendering;
// Windows.Media.Ocr for the first reading; Tesseract for the second reading of scans (and for the
// line confidences Windows OCR does not give). x64 only (the Tesseract package ships x64/x86
// native libraries, and Jack for Windows ships x64).
//
// What only Windows CI can prove (the Mac replay cannot): Windows OCR line/word geometry against
// Vision's, the Tesseract confidence mapping, and PDFium's isScanPage / text layer / gray render
// against PDFKit's.
using System.Runtime.InteropServices;
using Jack.Core.Word;
using Windows.Graphics.Imaging;
using OcrEngine = Windows.Media.Ocr.OcrEngine;
using OcrLine = Jack.Core.Word.OcrLine;
using OcrWord = Jack.Core.Word.OcrWord;
using Windows.Security.Cryptography;

namespace Jack.Core.Windows;

public sealed class WindowsPageSource : IPageSource
{
    readonly IntPtr doc;
    readonly int pageCount;
    readonly OcrEngine ocr;
    readonly Tesseract.TesseractEngine? tess;
    readonly Dictionary<int, (GrayImage Image, List<OcrLine> Lines)> tessCache = new();
    public readonly List<string> Warnings = new();

    /// `tessdata`: folder with eng.traineddata (and spa.traineddata, used when present). Without
    /// it scans get no second reading, so every word on a scan is marked to double-check.
    public WindowsPageSource(string pdfPath, string? tessdata)
    {
        if (RuntimeInformation.ProcessArchitecture != Architecture.X64)
            throw new PlatformNotSupportedException("Save as Word on Windows runs as an x64 process.");
        Pdfium.Init();
        doc = Pdfium.FPDF_LoadDocument(pdfPath, null);
        if (doc == IntPtr.Zero) throw new InvalidOperationException($"PDFium could not open {Path.GetFileName(pdfPath)} (error {Pdfium.FPDF_GetLastError()})");
        pageCount = Pdfium.FPDF_GetPageCount(doc);
        ocr = OcrEngine.TryCreateFromLanguage(new global::Windows.Globalization.Language("en-US"))
              ?? OcrEngine.TryCreateFromUserProfileLanguages()
              ?? throw new InvalidOperationException("Windows OCR has no language installed on this PC.");
        if (!string.IsNullOrEmpty(tessdata) && File.Exists(Path.Combine(tessdata, "eng.traineddata")))
        {
            var lang = File.Exists(Path.Combine(tessdata, "spa.traineddata")) ? "eng+spa" : "eng";
            tess = new Tesseract.TesseractEngine(tessdata, lang, Tesseract.EngineMode.LstmOnly);
            tess.SetVariable("user_defined_dpi", ((int)Math.Round(WordExportEngine.RenderScale * 72)).ToString());
        }
        else Warnings.Add("no Tesseract data: scans get no second reading, every word on a scan is marked to double-check");
    }

    public int PageCount => pageCount;

    T WithPage<T>(int index, Func<IntPtr, T> body)
    {
        var page = Pdfium.FPDF_LoadPage(doc, index);
        if (page == IntPtr.Zero) throw new InvalidOperationException($"PDFium could not load page {index + 1}");
        try { return body(page); } finally { Pdfium.FPDF_ClosePage(page); }
    }

    static (double X, double Y, double W, double H) MediaBox(IntPtr page)
    {
        if (Pdfium.FPDFPage_GetMediaBox(page, out var l, out var b, out var r, out var t) != 0 && r > l && t > b)
            return (l, b, r - l, t - b);
        return (0, 0, Pdfium.FPDF_GetPageWidthF(page), Pdfium.FPDF_GetPageHeightF(page));
    }

    public PageInfo Page(int index) => WithPage(index, page =>
    {
        var box = MediaBox(page);
        return new PageInfo(box.W, box.H, TextLayer(page), IsScanPage(page, box.W, box.H));
    });

    static string TextLayer(IntPtr page)
    {
        var tp = Pdfium.FPDFText_LoadPage(page);
        if (tp == IntPtr.Zero) return "";
        try
        {
            int n = Pdfium.FPDFText_CountChars(tp);
            if (n <= 0) return "";
            var buf = new ushort[n + 1];
            int got = Pdfium.FPDFText_GetText(tp, 0, n, buf);
            var chars = new char[Math.Max(0, got - 1)];
            for (int i = 0; i < chars.Length; i++) chars[i] = (char)buf[i];
            return new string(chars);
        }
        finally { Pdfium.FPDFText_ClosePage(tp); }
    }

    /// Mirror of the Mac rule: an image at least 1.4 px per point of page width whose aspect ratio
    /// is the page's (within 0.08) makes the page a scan. The Mac walks the page's XObject
    /// resources; PDFium gives the page's top-level image objects (forms are not entered on
    /// either side).
    static bool IsScanPage(IntPtr page, double W, double H)
    {
        int n = Pdfium.FPDFPage_CountObjects(page);
        for (int i = 0; i < n; i++)
        {
            var obj = Pdfium.FPDFPage_GetObject(page, i);
            if (obj == IntPtr.Zero || Pdfium.FPDFPageObj_GetType(obj) != Pdfium.PageObjImage) continue;
            if (Pdfium.FPDFImageObj_GetImagePixelSize(obj, out var w, out var h) == 0 || h == 0) continue;
            double ar = (double)w / h, pr = W / Math.Max(1, H);
            if (w >= W * 1.4 && Math.Abs(ar - pr) < 0.08) return true;
        }
        return false;
    }

    /// The Mac draws the media box; PDFium draws the crop box. Make them the same, in memory only
    /// (the document is never saved).
    static void DrawMediaBox(IntPtr page)
    {
        if (Pdfium.FPDFPage_GetMediaBox(page, out var l, out var b, out var r, out var t) != 0 && r > l && t > b)
            Pdfium.FPDFPage_SetCropBox(page, l, b, r, t);
    }

    public GrayImage? Render(int index) => WithPage(index, page =>
    {
        DrawMediaBox(page);
        var box = MediaBox(page);
        double s = WordExportEngine.RenderScale;
        int w = (int)(box.W * s), h = (int)(box.H * s);
        if (w <= 0 || h <= 0) return (GrayImage?)null;
        var bgra = Pdfium.RenderBgra(page, w, h, s, 0, 0);
        var px = new byte[w * h];
        for (int i = 0; i < px.Length; i++)
        {
            int o = i * 4;
            px[i] = (byte)((bgra[o + 2] * 299 + bgra[o + 1] * 587 + bgra[o] * 114 + 500) / 1000);
        }
        return new GrayImage(w, h, s, px);
    });

    public byte[]? RenderColorCrop(int index, Rect rect, double scale, int w, int h) => WithPage(index, page =>
    {
        DrawMediaBox(page);
        var bgra = Pdfium.RenderBgra(page, w, h, scale, rect.MinX, rect.MinY);
        for (int i = 0; i < w * h; i++)
        {
            int o = i * 4;
            (bgra[o], bgra[o + 2]) = (bgra[o + 2], bgra[o]);   // BGRA → RGBA
            bgra[o + 3] = 255;
        }
        return (byte[]?)bgra;
    });

    public IReadOnlyList<OcrLine> Recognize(int index, GrayImage g, double pageWidth, double pageHeight, bool correction)
    {
        var tl = TesseractLines(index, g);
        if (!correction) return tl ?? new List<OcrLine>();
        var lines = WindowsOcr(g);
        // Windows OCR gives no confidence. A line's confidence is the mean confidence Tesseract
        // gave the words it read inside that line (handwriting and smudges score low there too).
        if (tl == null) return lines;
        var tw = tl.SelectMany(l => l.Words.Select((w, k) => (w, conf: WordConf(l, k)))).ToList();
        return lines.Select(l =>
        {
            var inside = tw.Where(t => Inside(t.w, l)).Select(t => t.conf).ToList();
            float c = inside.Count == 0 ? 0.5f : inside.Average();
            return l with { Confidence = c };
        }).ToList();
    }

    // Tesseract word confidences, kept beside the lines (OcrWord carries no confidence).
    readonly Dictionary<OcrLine, float[]> wordConf = new(ReferenceEqualityComparer.Instance);
    float WordConf(OcrLine l, int k) => wordConf.TryGetValue(l, out var a) && k < a.Length ? a[k] : l.Confidence;

    static bool Inside(OcrWord w, OcrLine l)
    {
        double ix = Math.Min(w.X1, l.X1) - Math.Max(w.X0, l.X0), iy = Math.Min(w.Y1, l.Y1) - Math.Max(w.Y0, l.Y0);
        if (ix <= 0 || iy <= 0) return false;
        double area = Math.Max(1e-6, (w.X1 - w.X0) * (w.Y1 - w.Y0));
        return ix * iy / area > 0.5;
    }

    List<OcrLine> WindowsOcr(GrayImage g)
    {
        // Windows OCR takes at most MaxImageDimension pixels a side (2600 on current builds).
        double f = Math.Min(1.0, OcrEngine.MaxImageDimension / (double)Math.Max(g.W, g.H));
        int bw = Math.Max(1, (int)(g.W * f)), bh = Math.Max(1, (int)(g.H * f));
        var gray = f < 1 ? Downscale(g, bw, bh) : g.Px;
        var bgra = new byte[bw * bh * 4];
        for (int i = 0; i < bw * bh; i++) { int o = i * 4; bgra[o] = bgra[o + 1] = bgra[o + 2] = gray[i]; bgra[o + 3] = 255; }
        using var bmp = SoftwareBitmap.CreateCopyFromBuffer(CryptographicBuffer.CreateFromByteArray(bgra),
            BitmapPixelFormat.Bgra8, bw, bh, BitmapAlphaMode.Premultiplied);
        var result = ocr.RecognizeAsync(bmp).AsTask().GetAwaiter().GetResult();
        double sx = g.Scale * bw / g.W, sy = g.Scale * bh / g.H;     // pixels of the OCR'd bitmap per point
        var lines = new List<OcrLine>();
        foreach (var l in result.Lines)
        {
            var words = l.Words.Select(w => new OcrWord(w.Text,
                w.BoundingRect.X / sx, (w.BoundingRect.X + w.BoundingRect.Width) / sx,
                w.BoundingRect.Y / sy, (w.BoundingRect.Y + w.BoundingRect.Height) / sy)).ToList();
            if (words.Count == 0) continue;
            lines.Add(new OcrLine(l.Text, words.Min(w => w.X0), words.Max(w => w.X1), words.Min(w => w.Y0), words.Max(w => w.Y1), 1.0f, words));
        }
        return lines;
    }

    static byte[] Downscale(GrayImage g, int bw, int bh)
    {
        // Area average: every source pixel lands in exactly one target pixel.
        var sum = new long[bw * bh]; var cnt = new int[bw * bh];
        for (int y = 0; y < g.H; y++)
        {
            int ty = Math.Min(bh - 1, (int)((long)y * bh / g.H));
            for (int x = 0; x < g.W; x++)
            {
                int tx = Math.Min(bw - 1, (int)((long)x * bw / g.W));
                sum[ty * bw + tx] += g.Px[y * g.W + x]; cnt[ty * bw + tx]++;
            }
        }
        var px = new byte[bw * bh];
        for (int i = 0; i < px.Length; i++) px[i] = cnt[i] == 0 ? (byte)255 : (byte)((sum[i] + cnt[i] / 2) / cnt[i]);
        return px;
    }

    List<OcrLine>? TesseractLines(int index, GrayImage g)
    {
        if (tess == null) return null;
        if (tessCache.TryGetValue(index, out var hit) && ReferenceEquals(hit.Image, g)) return hit.Lines;
        var lines = new List<OcrLine>();
        using (var pix = Tesseract.Pix.LoadFromMemory(Bmp24(g)))
        using (var page = tess.Process(pix, Tesseract.PageSegMode.Auto))
        using (var it = page.GetIterator())
        {
            double s = g.Scale;
            it.Begin();
            var words = new List<OcrWord>(); var confs = new List<float>();
            float lineConf = 0;
            void Flush()
            {
                if (words.Count == 0) return;
                var l = new OcrLine(string.Join(" ", words.Select(w => w.Text)), words.Min(w => w.X0), words.Max(w => w.X1),
                                    words.Min(w => w.Y0), words.Max(w => w.Y1), lineConf, words.ToList());
                wordConf[l] = confs.ToArray();
                lines.Add(l);
                words.Clear(); confs.Clear();
            }
            do
            {
                if (it.IsAtBeginningOf(Tesseract.PageIteratorLevel.TextLine))
                {
                    Flush();
                    lineConf = Math.Clamp(it.GetConfidence(Tesseract.PageIteratorLevel.TextLine) / 100f, 0f, 1f);
                }
                if (!it.TryGetBoundingBox(Tesseract.PageIteratorLevel.Word, out var r)) continue;
                var text = it.GetText(Tesseract.PageIteratorLevel.Word)?.Trim();
                if (string.IsNullOrEmpty(text)) continue;
                words.Add(new OcrWord(text, r.X1 / s, r.X2 / s, r.Y1 / s, r.Y2 / s));
                confs.Add(Math.Clamp(it.GetConfidence(Tesseract.PageIteratorLevel.Word) / 100f, 0f, 1f));
            } while (it.Next(Tesseract.PageIteratorLevel.Word));
            Flush();
        }
        tessCache[index] = (g, lines);
        return lines;
    }

    static byte[] Bmp24(GrayImage g)
    {
        int row = (g.W * 3 + 3) & ~3;
        var data = new byte[54 + row * g.H];
        void I32(int o, int v) => BitConverter.GetBytes(v).CopyTo(data, o);
        data[0] = (byte)'B'; data[1] = (byte)'M';
        I32(2, data.Length); I32(10, 54); I32(14, 40); I32(18, g.W); I32(22, g.H);
        data[26] = 1; data[28] = 24; I32(34, row * g.H);
        int ppm = (int)Math.Round(g.Scale * 72 / 0.0254);
        I32(38, ppm); I32(42, ppm);
        for (int y = 0; y < g.H; y++)
        {
            int dst = 54 + (g.H - 1 - y) * row;
            for (int x = 0; x < g.W; x++)
            {
                byte v = g.Px[y * g.W + x];
                data[dst + x * 3] = v; data[dst + x * 3 + 1] = v; data[dst + x * 3 + 2] = v;
            }
        }
        return data;
    }

    public void Dispose()
    {
        tess?.Dispose();
        if (doc != IntPtr.Zero) Pdfium.FPDF_CloseDocument(doc);
    }
}
