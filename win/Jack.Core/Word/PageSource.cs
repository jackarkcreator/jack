// What the Save as Word engine needs from the outside world, per page. The engine never calls
// OCR or PDFium itself: Windows/WindowsPageSource reads real PDFs, Replay/ReplayPageSource plays
// back exactly what the Mac engine saw (JACK_WORD_DUMP), so both run the same engine code.
//
// Coordinates: points, TOP-LEFT origin (as the Swift engine's Item / Line). Images: 8-bit gray,
// row 0 = top of the page, `Scale` pixels per point.
namespace Jack.Core.Word;

public sealed class GrayImage
{
    public readonly int W, H;
    public readonly double Scale;
    public readonly byte[] Px;

    public GrayImage(int w, int h, double scale, byte[] px)
    {
        if (px.Length != w * h) throw new ArgumentException($"gray image is {px.Length} bytes, expected {w}x{h}");
        W = w; H = h; Scale = scale; Px = px;
    }

    public bool Dark(int c, int r) => Px[r * W + c] < 150;
}

/// One word as an OCR engine (or a text layer) returned it.
public sealed record OcrWord(string Text, double X0, double X1, double Y0, double Y1);

/// One line as an OCR engine returned it: its text, its box, its confidence (0–1) and its words.
public sealed record OcrLine(string Text, double X0, double X1, double Y0, double Y1, float Confidence, IReadOnlyList<OcrWord> Words);

public sealed record PageInfo(
    double Width, double Height,   // media box, points
    string TextLayer,              // the page's own text (untrimmed); "" when it has none
    bool IsScanPage);              // the page is one page-sized picture (a scan, even with an OCR layer under it)

public interface IPageSource : IDisposable
{
    int PageCount { get; }

    PageInfo Page(int index);

    /// The page drawn in gray at WordExportEngine.RenderScale (4.0 = 288 dpi), on white.
    GrayImage? Render(int index);

    /// OCR of `g` (the page image, deskewed when the engine straightened it). `correction` true =
    /// the first reading (language correction on); false = the independent second reading used
    /// for scans. Lines come back in the OCR engine's own order: the engine sorts them.
    IReadOnlyList<OcrLine> Recognize(int index, GrayImage g, double pageWidth, double pageHeight, bool correction);

    /// The letterhead block drawn in colour: RGBA, row 0 = top, `w`×`h` pixels, white paper,
    /// `rect` (points, top-left origin) scaled by `scale`. Null when it can't be drawn.
    byte[]? RenderColorCrop(int index, Rect rect, double scale, int w, int h);

    /// Only for replay: the exact image the Mac's rotation produced, so ink analysis after a
    /// deskew sees the same pixels. Real sources return null and the engine rotates itself.
    GrayImage? RotatedOverride(int index, GrayImage g, double degrees) => null;

    /// Only for replay: told the order the engine sorted a reading's lines into (indices into the
    /// list Recognize returned), so it can be checked against the Mac's.
    void SortedOrder(int index, bool correction, IReadOnlyList<int> order) { }
}

/// CGRect, with CoreGraphics' semantics: min/max/size are taken from the standardized rect, and
/// maxX = x + width computed in that order (so the ink windows land on the same pixels).
public readonly record struct Rect(double X, double Y, double Width, double Height)
{
    double SX => Width < 0 ? X + Width : X;
    double SY => Height < 0 ? Y + Height : Y;
    double SW => Width < 0 ? -Width : Width;
    double SH => Height < 0 ? -Height : Height;
    public double MinX => SX;
    public double MinY => SY;
    public double MaxX => SX + SW;
    public double MaxY => SY + SH;
    public double W => SW;
    public double H => SH;
}
