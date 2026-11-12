// Turning a gray page image about its centre, for deskewing scans on Windows.
// The Mac draws the image into a rotated CoreGraphics context (interpolation .high). This is a
// bilinear resampler with the same geometry: positive degrees turn the page counter-clockwise as
// seen, about the image centre, on white. Pixel values differ slightly from CoreGraphics'
// resampler; replay uses the Mac's own rotated pixels instead (IPageSource.RotatedOverride).
using Jack.Core.Word;

namespace Jack.Core.Imaging;

public static class Rotate
{
    public static GrayImage Gray(GrayImage g, double degrees)
    {
        int w = g.W, h = g.H;
        var px = new byte[w * h];
        double th = degrees * Math.PI / 180, cos = Math.Cos(th), sin = Math.Sin(th);
        double cx = w / 2.0, cy = h / 2.0;
        var src = g.Px;
        Parallel.For(0, h, y =>
        {
            // Work in y-up coordinates about the centre: out = R(θ)·in, so in = R(−θ)·out.
            double v = cy - (y + 0.5);
            for (int x = 0; x < w; x++)
            {
                double u = (x + 0.5) - cx;
                double iu = cos * u + sin * v;
                double iv = -sin * u + cos * v;
                double sx = cx + iu - 0.5, sy = cy - iv - 0.5;
                int x0 = (int)Math.Floor(sx), y0 = (int)Math.Floor(sy);
                double fx = sx - x0, fy = sy - y0;
                double S(int xx, int yy) => xx < 0 || yy < 0 || xx >= w || yy >= h ? 255 : src[yy * w + xx];
                double top = S(x0, y0) * (1 - fx) + S(x0 + 1, y0) * fx;
                double bot = S(x0, y0 + 1) * (1 - fx) + S(x0 + 1, y0 + 1) * fx;
                double val = top * (1 - fy) + bot * fy;
                px[y * w + x] = (byte)Math.Clamp((int)Math.Round(val), 0, 255);
            }
        });
        return new GrayImage(w, h, g.Scale, px);
    }
}
