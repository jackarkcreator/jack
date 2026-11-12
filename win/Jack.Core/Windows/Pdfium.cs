// The PDFium surface Save as Word needs on Windows: open, page size (media box), text layer,
// page objects (for the scan test) and rendering through a matrix. pdfium.dll is the
// bblanchon/pdfium-binaries build already used by the Windows spike.
using System.Runtime.InteropServices;

namespace Jack.Core.Windows;

[StructLayout(LayoutKind.Sequential)]
internal struct FsMatrix { public float A, B, C, D, E, F; }

[StructLayout(LayoutKind.Sequential)]
internal struct FsRectF { public float Left, Top, Right, Bottom; }

[StructLayout(LayoutKind.Sequential)]
internal struct FileWrite { public int Version; public IntPtr WriteBlock; }

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
internal delegate int WriteBlockFn(IntPtr self, IntPtr data, uint size);

/// PDFium could not open the file. `Code` is FPDF_GetLastError (4 = needs a password).
public sealed class PdfOpenException : InvalidOperationException
{
    public readonly uint Code;
    public bool NeedsPassword => Code == 4;
    public PdfOpenException(string file, uint code) : base($"PDFium could not open {file} (error {code})") { Code = code; }
}

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
    [DllImport(D)] public static extern uint FPDFText_GetUnicode(IntPtr text, int index);
    [DllImport(D)] public static extern int FPDFText_GetCharBox(IntPtr text, int index, out double left, out double right, out double bottom, out double top);

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

    [DllImport(D)] public static extern int FPDFPage_GetRotation(IntPtr page);

    // Writing (Make Searchable): invisible text objects on a loaded page, then save a NEW file.
    [DllImport(D)] public static extern IntPtr FPDFText_LoadStandardFont(IntPtr doc, [MarshalAs(UnmanagedType.LPStr)] string name);
    [DllImport(D)] public static extern void FPDFFont_Close(IntPtr font);
    [DllImport(D)] public static extern IntPtr FPDFPageObj_CreateTextObj(IntPtr doc, IntPtr font, float size);
    [DllImport(D)] public static extern int FPDFText_SetText(IntPtr obj, [MarshalAs(UnmanagedType.LPWStr)] string text);
    [DllImport(D)] public static extern int FPDFTextObj_SetTextRenderMode(IntPtr obj, int mode);
    [DllImport(D)] public static extern void FPDFPageObj_Transform(IntPtr obj, double a, double b, double c, double d, double e, double f);
    [DllImport(D)] public static extern int FPDFPageObj_GetBounds(IntPtr obj, out float left, out float bottom, out float right, out float top);
    [DllImport(D)] public static extern void FPDFPageObj_Destroy(IntPtr obj);
    [DllImport(D)] public static extern void FPDFPage_InsertObject(IntPtr page, IntPtr obj);
    [DllImport(D)] public static extern int FPDFPage_GenerateContent(IntPtr page);
    [DllImport(D)] public static extern int FPDF_SaveAsCopy(IntPtr doc, ref FileWrite fileWrite, uint flags);

    public const int TextRenderInvisible = 3;
    public const uint SaveNoIncremental = 2;
    public const int PageObjImage = 3;
    public const int RenderAnnotations = 0x01;

    public static IntPtr Open(string path)
    {
        Init();
        var doc = FPDF_LoadDocument(path, null);
        if (doc == IntPtr.Zero) throw new PdfOpenException(Path.GetFileName(path), FPDF_GetLastError());
        return doc;
    }

    /// Writes `doc` as a complete new file at `path` (created, never appended to).
    public static void SaveAsNew(IntPtr doc, string path)
    {
        using var fs = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        Exception? failure = null;
        WriteBlockFn fn = (_, data, size) =>
        {
            try
            {
                var buf = new byte[size];
                Marshal.Copy(data, buf, 0, (int)size);
                fs.Write(buf, 0, buf.Length);
                return 1;
            }
            catch (Exception e) { failure ??= e; return 0; }
        };
        var fw = new FileWrite { Version = 1, WriteBlock = Marshal.GetFunctionPointerForDelegate(fn) };
        bool ok = FPDF_SaveAsCopy(doc, ref fw, SaveNoIncremental) != 0;
        GC.KeepAlive(fn);
        if (failure != null) throw new IOException("writing the PDF failed", failure);
        if (!ok) throw new InvalidOperationException("PDFium could not save the PDF");
        fs.Flush(true);
    }

    /// Every page's text as PDFium extracts it (what a viewer's search and copy see).
    public static List<string> PageTexts(string path)
    {
        var doc = Open(path);
        try
        {
            var pages = new List<string>();
            int n = FPDF_GetPageCount(doc);
            for (int i = 0; i < n; i++)
            {
                var page = FPDF_LoadPage(doc, i);
                if (page == IntPtr.Zero) { pages.Add(""); continue; }
                try { pages.Add(PageText(page)); } finally { FPDF_ClosePage(page); }
            }
            return pages;
        }
        finally { FPDF_CloseDocument(doc); }
    }

    public static string PageText(IntPtr page)
    {
        var tp = FPDFText_LoadPage(page);
        if (tp == IntPtr.Zero) return "";
        try
        {
            int n = FPDFText_CountChars(tp);
            if (n <= 0) return "";
            var buf = new ushort[n + 1];
            int got = FPDFText_GetText(tp, 0, n, buf);
            var chars = new char[Math.Max(0, got - 1)];
            for (int i = 0; i < chars.Length; i++) chars[i] = (char)buf[i];
            return new string(chars);
        }
        finally { FPDFText_ClosePage(tp); }
    }

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
