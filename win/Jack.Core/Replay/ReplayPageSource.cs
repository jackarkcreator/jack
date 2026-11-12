// Plays back what the Mac engine read (JACK_WORD_DUMP=<dir>, see WordDump in
// Sources/WordExportEngine.swift), so the C# engine can run on exactly the Mac's inputs with no
// OCR and no PDFium: page sizes, the scan test, the text layer, the rendered gray image, both
// Vision readings (in Vision's own order) and the letterhead crop.
//
// Every image is checked against the FNV-1a hash the Mac wrote, and every OCR request is checked
// against the image Vision actually saw. Anything that does not line up is counted in Warnings
// (the CLI prints them): a replay that silently diverged would prove nothing.
using System.Text.Json;
using Jack.Core.Imaging;
using Jack.Core.Word;

namespace Jack.Core.Replay;

public sealed class ReplayPageSource : IPageSource
{
    readonly string dir;
    readonly bool useMacRotation;
    readonly JsonElement[] pages;
    readonly Dictionary<int, GrayImage> deskewCache = new();
    public readonly List<string> Warnings = new();
    public int SortChecks, SortMismatches;

    /// `dir` holds meta.json and p<N>.json. `useMacRotation` false makes the engine deskew with
    /// its own rotation (as on Windows) instead of the Mac's rotated pixels.
    public ReplayPageSource(string dir, bool useMacRotation = true)
    {
        this.dir = dir;
        this.useMacRotation = useMacRotation;
        using var meta = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(dir, "meta.json")));
        int n = meta.RootElement.GetProperty("pageCount").GetInt32();
        double scale = meta.RootElement.GetProperty("renderScale").GetDouble();
        if (scale != WordExportEngine.RenderScale) Warn($"dump render scale {scale} is not {WordExportEngine.RenderScale}");
        pages = new JsonElement[n];
        for (int i = 0; i < n; i++)
        {
            var path = Path.Combine(dir, $"p{i + 1}.json");
            // A page the Mac could not render has no dump (read() returned early): replay it as blank.
            pages[i] = File.Exists(path) ? JsonDocument.Parse(File.ReadAllBytes(path)).RootElement.Clone() : default;
        }
    }

    public int PageCount => pages.Length;

    void Warn(string s) { Warnings.Add(s); }

    bool Has(int i) => pages[i].ValueKind == JsonValueKind.Object;

    public PageInfo Page(int index)
    {
        if (!Has(index)) { Warn($"p{index + 1}: no dump"); return new PageInfo(612, 792, "", false); }
        var p = pages[index];
        return new PageInfo(p.GetProperty("width").GetDouble(), p.GetProperty("height").GetDouble(),
                            p.GetProperty("pageString").GetString() ?? "", p.GetProperty("isScanPage").GetBoolean());
    }

    GrayImage LoadGray(JsonElement e, string what)
    {
        var file = e.GetProperty("file").GetString()!;
        var img = Png.Decode(File.ReadAllBytes(Path.Combine(dir, file)));
        if (img.Channels != 1) throw new InvalidDataException($"{file}: expected a gray PNG, got {img.Channels} channels");
        int w = e.GetProperty("w").GetInt32(), h = e.GetProperty("h").GetInt32();
        if (img.Width != w || img.Height != h) Warn($"{what}: PNG is {img.Width}x{img.Height}, dump says {w}x{h}");
        var hash = Fnv.Hash(img.Pixels);
        if (hash != e.GetProperty("fnv").GetString()) Warn($"{what}: pixels hash {hash}, Mac's {e.GetProperty("fnv").GetString()}");
        return new GrayImage(img.Width, img.Height, e.GetProperty("scale").GetDouble(), img.Pixels);
    }

    public GrayImage? Render(int index) => Has(index) ? LoadGray(pages[index].GetProperty("render"), $"p{index + 1} render") : null;

    public GrayImage? RotatedOverride(int index, GrayImage g, double degrees)
    {
        if (!Has(index)) return null;
        var p = pages[index];
        var skew = p.GetProperty("skew");
        var desk = p.GetProperty("deskewed");
        if (desk.ValueKind != JsonValueKind.Object)
        {
            Warn($"p{index + 1}: engine deskews by {degrees}, the Mac did not");
            return null;
        }
        double macSkew = skew.GetDouble();
        if (macSkew != degrees) Warn($"p{index + 1}: engine skew {degrees:R}, Mac's {macSkew:R}");
        if (!useMacRotation) return null;
        if (!deskewCache.TryGetValue(index, out var img))
            deskewCache[index] = img = LoadGray(desk, $"p{index + 1} deskew");
        return img;
    }

    public IReadOnlyList<OcrLine> Recognize(int index, GrayImage g, double pageWidth, double pageHeight, bool correction)
    {
        if (!Has(index)) return Array.Empty<OcrLine>();
        var p = pages[index];
        // The image the engine asks about must be the image Vision read.
        var desk = p.GetProperty("deskewed");
        var saw = desk.ValueKind == JsonValueKind.Object ? desk : p.GetProperty("render");
        var hash = Fnv.Hash(g.Px);
        if (hash != saw.GetProperty("fnv").GetString())
            Warn($"p{index + 1}: OCR asked about an image (hash {hash}) that is not the one Vision read ({saw.GetProperty("fnv").GetString()}); replaying Vision's reading anyway");
        var reading = p.GetProperty(correction ? "first" : "second");
        if (reading.ValueKind != JsonValueKind.Object)
        {
            Warn($"p{index + 1}: the Mac made no {(correction ? "first" : "second")} reading");
            return Array.Empty<OcrLine>();
        }
        var lines = new List<OcrLine>();
        foreach (var l in reading.GetProperty("lines").EnumerateArray())
        {
            var words = l.GetProperty("items").EnumerateArray().Select(w => new OcrWord(w.GetProperty("text").GetString() ?? "",
                w.GetProperty("x0").GetDouble(), w.GetProperty("x1").GetDouble(), w.GetProperty("y0").GetDouble(), w.GetProperty("y1").GetDouble())).ToList();
            lines.Add(new OcrLine(l.GetProperty("text").GetString() ?? "",
                l.GetProperty("x0").GetDouble(), l.GetProperty("x1").GetDouble(), l.GetProperty("y0").GetDouble(), l.GetProperty("y1").GetDouble(),
                l.GetProperty("confidence").GetSingle(), words));
        }
        return lines;
    }

    public void SortedOrder(int index, bool correction, IReadOnlyList<int> order)
    {
        if (!Has(index)) return;
        var reading = pages[index].GetProperty(correction ? "first" : "second");
        if (reading.ValueKind != JsonValueKind.Object) return;
        var mac = reading.GetProperty("sortedOrder").EnumerateArray().Select(e => e.GetInt32()).ToList();
        SortChecks++;
        if (!mac.SequenceEqual(order))
        {
            SortMismatches++;
            Warn($"p{index + 1} {(correction ? "first" : "second")} reading: line order differs from the Mac's");
        }
    }

    public byte[]? RenderColorCrop(int index, Rect rect, double scale, int w, int h)
    {
        var path = Path.Combine(dir, "letterhead.json");
        if (!File.Exists(path)) { Warn("engine wants a letterhead the Mac did not make"); return null; }
        using var doc = JsonDocument.Parse(File.ReadAllBytes(path));
        var e = doc.RootElement;
        if (e.GetProperty("page").GetInt32() != index || e.GetProperty("w").GetInt32() != w || e.GetProperty("h").GetInt32() != h
            || e.GetProperty("x").GetDouble() != rect.X || e.GetProperty("y").GetDouble() != rect.Y
            || e.GetProperty("width").GetDouble() != rect.Width || e.GetProperty("height").GetDouble() != rect.Height)
            Warn($"letterhead crop differs: engine p{index + 1} {rect} {w}x{h}");
        var img = Png.Decode(File.ReadAllBytes(Path.Combine(dir, e.GetProperty("raw").GetString()!)));
        byte[] rgba = img.Channels switch
        {
            4 => img.Pixels,
            3 => Enumerable.Range(0, img.Width * img.Height).SelectMany(i => new[] { img.Pixels[i * 3], img.Pixels[i * 3 + 1], img.Pixels[i * 3 + 2], (byte)255 }).ToArray(),
            _ => throw new InvalidDataException("letterhead crop is not RGB(A)"),
        };
        var hash = Fnv.Hash(rgba);
        if (hash != e.GetProperty("rawFnv").GetString()) Warn($"letterhead crop pixels hash {hash}, Mac's {e.GetProperty("rawFnv").GetString()}");
        return rgba;
    }

    /// After an export: do the lifted letterhead pixels match the Mac's?
    public void CheckLetterhead(byte[]? lifted)
    {
        var path = Path.Combine(dir, "letterhead.json");
        if (!File.Exists(path) || lifted == null) return;
        using var doc = JsonDocument.Parse(File.ReadAllBytes(path));
        var mac = doc.RootElement.GetProperty("liftedFnv").GetString();
        var hash = Fnv.Hash(lifted);
        if (hash != mac) Warn($"lifted letterhead pixels hash {hash}, Mac's {mac}");
    }

    public void Dispose() { }
}
