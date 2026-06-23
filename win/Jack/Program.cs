// Jack (Windows) — drop photos, get one resized PDF.
// ThinkOpen Inc. Windows counterpart to the macOS droplet; same behavior:
// resize to 1600px long edge, merge to one PDF on the Desktop, never touch originals.
using System.Drawing;
using System.Drawing.Imaging;
using System.Diagnostics;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using PdfSharp.Drawing;
using PdfSharp.Pdf;

namespace Jack;

internal static class Program
{
    private const int MaxEdge = 1600;
    private const long JpegQuality = 72;
    private static readonly string[] Exts = { ".jpg", ".jpeg", ".png", ".bmp", ".gif", ".tif", ".tiff" };

    [STAThread]
    private static int Main(string[] args)
    {
        Application.EnableVisualStyles();

        var inputs = args.Where(File.Exists).ToList();
        if (inputs.Count == 0)
        {
            using var dlg = new OpenFileDialog
            {
                Multiselect = true,
                Title = "Choose photos to combine into one PDF",
                Filter = "Images|*.jpg;*.jpeg;*.png;*.bmp;*.gif;*.tif;*.tiff|All files|*.*"
            };
            if (dlg.ShowDialog() != DialogResult.OK) return 0;
            inputs = dlg.FileNames.ToList();
        }

        var images = inputs
            .Where(p => Exts.Contains(Path.GetExtension(p).ToLowerInvariant()))
            .OrderBy(Path.GetFileName, new NaturalComparer())
            .ToList();

        if (images.Count == 0)
        {
            Info("No images found", "Drop photos (JPEG, PNG, TIFF…) onto Jack and it will resize them and build one PDF.");
            return 1;
        }

        var temps = new List<string>();
        var skipped = new List<string>();
        try
        {
            using var doc = new PdfDocument();
            foreach (var path in images)
            {
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
                catch
                {
                    skipped.Add(Path.GetFileName(path));
                }
            }

            if (doc.PageCount == 0)
            {
                Info("Couldn’t read those images", "None of the dropped files could be processed.");
                return 1;
            }

            var outPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                $"Jack_{DateTime.Now:yyyy-MM-dd_HHmmss}.pdf");
            doc.Save(outPath);

            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{outPath}\"") { UseShellExecute = true });

            if (skipped.Count > 0)
                Info("PDF created",
                     $"Saved {doc.PageCount} page(s) to {Path.GetFileName(outPath)} on your Desktop.\n\nSkipped (unreadable): {string.Join(", ", skipped)}");
        }
        catch (Exception ex)
        {
            Info("Something went wrong", ex.Message);
            return 1;
        }
        finally
        {
            foreach (var t in temps) { try { File.Delete(t); } catch { /* best effort */ } }
        }
        return 0;
    }

    // Resize to MaxEdge on the long edge (never upscales), honoring EXIF orientation,
    // re-encode as JPEG. Writes a temp file; the original is never modified.
    private static string ResizeToTempJpeg(string path)
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
        ps.Param[0] = new EncoderParameter(Encoder.Quality, JpegQuality);
        dst.Save(tmp, enc, ps);
        return tmp;
    }

    private static void ApplyExifOrientation(Bitmap bmp)
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
        if (flip != RotateFlipType.RotateNoneFlipNone)
        {
            bmp.RotateFlip(flip);
            bmp.RemovePropertyItem(OrientationId);
        }
    }

    private static void Info(string title, string body) =>
        MessageBox.Show(body, title, MessageBoxButtons.OK, MessageBoxIcon.Information);
}

// Natural ("IMG_2" before "IMG_10") filename ordering, matching the Mac app.
internal sealed class NaturalComparer : IComparer<string>
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
