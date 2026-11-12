// Photos to one PDF: the v1.1.0 Windows exe's behaviour, unchanged, moved into the app.
// Resize to 1600 px on the long edge (never upscales, EXIF orientation honoured), JPEG quality 72,
// one page per photo in natural name order, saved as Jack_<timestamp>.pdf on the Desktop.
// Originals are never touched.
using System.Drawing;
using System.Drawing.Imaging;
using System.Text.RegularExpressions;
using PdfSharp.Drawing;
using PdfSharp.Pdf;

namespace Jack.App;

internal static class PhotosToPdf
{
    const int MaxEdge = 1600;
    const long JpegQuality = 72;
    public static readonly string[] Exts = { ".jpg", ".jpeg", ".png", ".bmp", ".gif", ".tif", ".tiff" };

    public static bool IsPhoto(string path) => Exts.Contains(Path.GetExtension(path).ToLowerInvariant());

    public sealed record Result(string Path, int Pages, List<string> Skipped);

    /// Builds the PDF. Throws when no photo could be read. `outDir` defaults to the Desktop.
    public static Result Make(IEnumerable<string> inputs, string? outDir = null, Func<bool>? cancelled = null)
    {
        var images = inputs.Where(IsPhoto).OrderBy(Path.GetFileName, new NaturalComparer()).ToList();
        if (images.Count == 0) throw new InvalidOperationException("No photos to combine.");
        var temps = new List<string>();
        var skipped = new List<string>();
        try
        {
            using var doc = new PdfDocument();
            foreach (var path in images)
            {
                if (cancelled?.Invoke() == true) throw new OperationCanceledException();
                try
                {
                    var tmp = ResizeToTempJpeg(path);
                    temps.Add(tmp);
                    using var img = XImage.FromFile(tmp);
                    var page = doc.AddPage();
                    page.Width = XUnit.FromPoint(img.PixelWidth);
                    page.Height = XUnit.FromPoint(img.PixelHeight);
                    using var gfx = XGraphics.FromPdfPage(page);
                    gfx.DrawImage(img, 0, 0, page.Width.Point, page.Height.Point);
                }
                catch (Exception e) when (e is not OperationCanceledException) { skipped.Add(Path.GetFileName(path)); }
            }
            if (doc.PageCount == 0) throw new InvalidOperationException("None of the photos could be read.");
            outDir ??= Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            var outPath = Path.Combine(outDir, $"Jack_{DateTime.Now:yyyy-MM-dd_HHmmss}.pdf");
            for (int n = 2; File.Exists(outPath); n++) outPath = Path.Combine(outDir, $"Jack_{DateTime.Now:yyyy-MM-dd_HHmmss} {n}.pdf");
            doc.Save(outPath);
            return new Result(outPath, doc.PageCount, skipped);
        }
        finally
        {
            foreach (var t in temps) { try { File.Delete(t); } catch { } }
        }
    }

    static string ResizeToTempJpeg(string path)
    {
        using var src = new Bitmap(path);
        ApplyExifOrientation(src);
        double scale = Math.Min(1.0, (double)MaxEdge / Math.Max(src.Width, src.Height));
        int w = Math.Max(1, (int)Math.Round(src.Width * scale));
        int h = Math.Max(1, (int)Math.Round(src.Height * scale));
        using var dst = new Bitmap(w, h);
        using (var g = Graphics.FromImage(dst))
        {
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
            g.DrawImage(src, 0, 0, w, h);
        }
        var tmp = Path.Combine(Path.GetTempPath(), $"jack_{Guid.NewGuid():N}.jpg");
        var enc = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
        using var ps = new EncoderParameters(1);
        ps.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, JpegQuality);
        dst.Save(tmp, enc, ps);
        return tmp;
    }

    static void ApplyExifOrientation(Bitmap bmp)
    {
        const int OrientationId = 0x0112;
        if (!bmp.PropertyIdList.Contains(OrientationId)) return;
        int o = bmp.GetPropertyItem(OrientationId)!.Value![0];
        var flip = o switch
        {
            2 => RotateFlipType.RotateNoneFlipX,
            3 => RotateFlipType.Rotate180FlipNone,
            4 => RotateFlipType.Rotate180FlipX,
            5 => RotateFlipType.Rotate90FlipX,
            6 => RotateFlipType.Rotate90FlipNone,
            7 => RotateFlipType.Rotate270FlipX,
            8 => RotateFlipType.Rotate270FlipNone,
            _ => RotateFlipType.RotateNoneFlipNone
        };
        if (flip != RotateFlipType.RotateNoneFlipNone) { bmp.RotateFlip(flip); bmp.RemovePropertyItem(OrientationId); }
    }
}

/// Natural ("IMG_2" before "IMG_10") file name order, as on the Mac.
internal sealed class NaturalComparer : IComparer<string?>
{
    public int Compare(string? a, string? b)
    {
        a ??= ""; b ??= "";
        var ax = Regex.Split(a, "([0-9]+)");
        var bx = Regex.Split(b, "([0-9]+)");
        for (int i = 0; i < Math.Min(ax.Length, bx.Length); i++)
        {
            int c = (int.TryParse(ax[i], out var an) && int.TryParse(bx[i], out var bn))
                ? an.CompareTo(bn)
                : string.Compare(ax[i], bx[i], StringComparison.OrdinalIgnoreCase);
            if (c != 0) return c;
        }
        return ax.Length.CompareTo(bx.Length);
    }
}
