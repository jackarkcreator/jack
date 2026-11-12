// The PDFium surface Save as Word needs on Windows: open, page size (media box), text layer,
// page objects (for the scan test) and rendering through a matrix. pdfium.dll is the
// bblanchon/pdfium-binaries build already used by the Windows spike.
using System.Runtime.InteropServices;

namespace Jack.Core.Windows;

[StructLayout(LayoutKind.Sequential)]
internal struct FsMatrix { public float A, B, C, D, E, F; }

[StructLayout(LayoutKind.Sequential)]
internal struct FsRectF { public float Left, Top, Right, Bottom; }

internal static class Pdfium
{
    const string D = "pdfium";

    [DllImport(D)] public static extern void FPDF_InitLibrary();
    [DllImport(D)] public static extern IntPtr FPDF_LoadDocument([MarshalAs(UnmanagedType.LPUTF8Str)] string path, [MarshalAs(UnmanagedType.LPStr)] string? password);
    [DllImport(D)] public static extern void FPDF_CloseDocument(IntPtr doc);
    [DllImport(D)] public static extern uint FPDF_GetLastError();
    [DllImport(D)] public static extern int FPDF_GetPageCount(IntPtr doc);
    [DllImport(D)] public static extern IntPtr FPDF_LoadPage(IntPtr doc, int index);
    [DllImport(D)] public static extern void FPDF_ClosePage(IntPtr page);
    [DllImport(D)] public static extern float FPDF_GetPageWidthF(IntPtr page);
    [DllImport(D)] public static extern float FPDF_GetPageHeightF(IntPtr page);
    [DllImport(D)] public static extern int FPDFPage_GetMediaBox(IntPtr page, out float left, out float bottom, out float right, out float top);
    [DllImport(D)] public static extern void FPDFPage_SetCropBox(IntPtr page, float left, float bottom, float right, float top);

    [DllImport(D)] public static extern IntPtr FPDFText_LoadPage(IntPtr page);
    [DllImport(D)] public static extern void FPDFText_ClosePage(IntPtr text);
    [DllImport(D)] public static extern int FPDFText_CountChars(IntPtr text);
    [DllImport(D)] public static extern int FPDFText_GetText(IntPtr text, int start, int count, [Out] ushort[] result);

    [DllImport(D)] public static extern int FPDFPage_CountObjects(IntPtr page);
    [DllImport(D)] public static extern IntPtr FPDFPage_GetObject(IntPtr page, int index);
    [DllImport(D)] public static extern int FPDFPageObj_GetType(IntPtr obj);
    [DllImport(D)] public static extern int FPDFImageObj_GetImagePixelSize(IntPtr obj, out uint width, out uint height);

    [DllImport(D)] public static extern IntPtr FPDFBitmap_Create(int width, int height, int alpha);
    [DllImport(D)] public static extern int FPDFBitmap_FillRect(IntPtr bmp, int left, int top, int width, int height, uint color);
    [DllImport(D)] public static extern void FPDF_RenderPageBitmapWithMatrix(IntPtr bmp, IntPtr page, ref FsMatrix matrix, ref FsRectF clipping, int flags);
    [DllImport(D)] public static extern IntPtr FPDFBitmap_GetBuffer(IntPtr bmp);
    [DllImport(D)] public static extern int FPDFBitmap_GetStride(IntPtr bmp);
    [DllImport(D)] public static extern void FPDFBitmap_Destroy(IntPtr bmp);

    public const int PageObjImage = 3;
    public const int RenderAnnotations = 0x01;

    static bool inited;
    public static void Init()
    {
        if (inited) return;
        FPDF_InitLibrary();
        inited = true;
    }

    /// The page drawn into a BGRx bitmap through `scale` and a top-left offset (points), on white.
    /// Returns BGRA bytes, row 0 = top.
    public static byte[] RenderBgra(IntPtr page, int w, int h, double scale, double offX, double offY)
    {
        var bmp = FPDFBitmap_Create(w, h, 0);
        if (bmp == IntPtr.Zero) throw new InvalidOperationException($"PDFium could not allocate a {w}x{h} bitmap");
        try
        {
            FPDFBitmap_FillRect(bmp, 0, 0, w, h, 0xFFFFFFFF);
            // PDFium first maps the page to top-left points (its display matrix), then applies this.
            var m = new FsMatrix { A = (float)scale, B = 0, C = 0, D = (float)scale, E = (float)(-offX * scale), F = (float)(-offY * scale) };
            var clip = new FsRectF { Left = 0, Top = 0, Right = w, Bottom = h };
            FPDF_RenderPageBitmapWithMatrix(bmp, page, ref m, ref clip, RenderAnnotations);
            var buf = FPDFBitmap_GetBuffer(bmp);
            int stride = FPDFBitmap_GetStride(bmp);
            var px = new byte[w * h * 4];
            for (int y = 0; y < h; y++) Marshal.Copy(buf + y * stride, px, y * w * 4, w * 4);
            return px;
        }
        finally { FPDFBitmap_Destroy(bmp); }
    }
}
