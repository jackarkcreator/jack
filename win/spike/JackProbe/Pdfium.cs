// Minimal PDFium P/Invoke surface for the spike: open, text with boxes, render, and write
// (text objects, image objects, save a copy). pdfium.dll comes from bblanchon/pdfium-binaries,
// pinned by tag and SHA-256 in the workflow.
using System.Runtime.InteropServices;

namespace JackProbe;

[StructLayout(LayoutKind.Sequential)]
struct FileWrite
{
    public int Version;
    public IntPtr WriteBlock;
}

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
delegate int WriteBlockFn(IntPtr self, IntPtr data, uint size);

static class P
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

    [DllImport(D)] public static extern IntPtr FPDFText_LoadPage(IntPtr page);
    [DllImport(D)] public static extern void FPDFText_ClosePage(IntPtr text);
    [DllImport(D)] public static extern int FPDFText_CountChars(IntPtr text);
    [DllImport(D)] public static extern uint FPDFText_GetUnicode(IntPtr text, int index);
    [DllImport(D)] public static extern int FPDFText_GetCharBox(IntPtr text, int index, out double left, out double right, out double bottom, out double top);

    [DllImport(D)] public static extern IntPtr FPDFBitmap_Create(int width, int height, int alpha);
    [DllImport(D)] public static extern int FPDFBitmap_FillRect(IntPtr bmp, int left, int top, int width, int height, uint color);
    [DllImport(D)] public static extern void FPDF_RenderPageBitmap(IntPtr bmp, IntPtr page, int x, int y, int w, int h, int rotate, int flags);
    [DllImport(D)] public static extern IntPtr FPDFBitmap_GetBuffer(IntPtr bmp);
    [DllImport(D)] public static extern int FPDFBitmap_GetStride(IntPtr bmp);
    [DllImport(D)] public static extern void FPDFBitmap_Destroy(IntPtr bmp);

    [DllImport(D)] public static extern IntPtr FPDF_CreateNewDocument();
    [DllImport(D)] public static extern IntPtr FPDFPage_New(IntPtr doc, int index, double width, double height);
    [DllImport(D)] public static extern IntPtr FPDFText_LoadStandardFont(IntPtr doc, [MarshalAs(UnmanagedType.LPStr)] string name);
    [DllImport(D)] public static extern void FPDFFont_Close(IntPtr font);
    [DllImport(D)] public static extern IntPtr FPDFPageObj_CreateTextObj(IntPtr doc, IntPtr font, float size);
    [DllImport(D)] public static extern int FPDFText_SetText(IntPtr obj, [MarshalAs(UnmanagedType.LPWStr)] string text);
    [DllImport(D)] public static extern int FPDFTextObj_SetTextRenderMode(IntPtr obj, int mode);
    [DllImport(D)] public static extern void FPDFPageObj_Transform(IntPtr obj, double a, double b, double c, double d, double e, double f);
    [DllImport(D)] public static extern int FPDFPageObj_GetBounds(IntPtr obj, out float left, out float bottom, out float right, out float top);
    [DllImport(D)] public static extern void FPDFPage_InsertObject(IntPtr page, IntPtr obj);
    [DllImport(D)] public static extern int FPDFPage_GenerateContent(IntPtr page);
    [DllImport(D)] public static extern IntPtr FPDFPageObj_NewImageObj(IntPtr doc);
    [DllImport(D)] public static extern int FPDFImageObj_SetBitmap(IntPtr pages, int count, IntPtr image, IntPtr bitmap);
    [DllImport(D)] public static extern int FPDFImageObj_SetMatrix(IntPtr image, double a, double b, double c, double d, double e, double f);
    [DllImport(D)] public static extern int FPDF_SaveAsCopy(IntPtr doc, ref FileWrite fileWrite, uint flags);

    public const int RenderAnnotations = 0x01;
    public const int TextRenderInvisible = 3;
    public const uint NoIncremental = 2;

    public static IntPtr Open(string path)
    {
        var doc = FPDF_LoadDocument(path, null);
        if (doc == IntPtr.Zero) throw new InvalidOperationException($"PDFium could not open {Path.GetFileName(path)} (error {FPDF_GetLastError()})");
        return doc;
    }

    public static void Save(IntPtr doc, string path)
    {
        using var fs = File.Create(path);
        WriteBlockFn fn = (_, data, size) =>
        {
            var buf = new byte[size];
            Marshal.Copy(data, buf, 0, (int)size);
            fs.Write(buf, 0, buf.Length);
            return 1;
        };
        var fw = new FileWrite { Version = 1, WriteBlock = Marshal.GetFunctionPointerForDelegate(fn) };
        var ok = FPDF_SaveAsCopy(doc, ref fw, NoIncremental) != 0;
        GC.KeepAlive(fn);
        if (!ok) throw new InvalidOperationException("FPDF_SaveAsCopy failed");
    }
}
