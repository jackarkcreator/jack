// Jack (Windows) command line.
//   Jack word <in.pdf> <out.docx> [--tessdata DIR] [--replay DIR] [--own-rotation]
// Exit 0 = wrote the .docx, 3 = refused (a line "REFUSED: <reason>"), anything else = failed.
// --replay DIR plays back a Mac dump (harness/run_engine.py --mac … --dump) instead of reading
// the PDF: DIR is one PDF's dump folder, or the dump root holding a folder named after the PDF.
// --own-rotation (replay only) deskews with the Windows rotation instead of the Mac's pixels.
using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using Jack.Core.Replay;
using Jack.Core.Word;

namespace Jack.Cli;

internal static class Program
{
    static int Main(string[] args)
    {
        CultureInfo.DefaultThreadCurrentCulture = CultureInfo.InvariantCulture;
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        if (args.Length < 3 || args[0] != "word")
        {
            Console.Error.WriteLine("usage: Jack word <in.pdf> <out.docx> [--tessdata DIR] [--replay DIR] [--own-rotation]");
            return 2;
        }
        string input = args[1], output = args[2];
        string? Opt(string name)
        {
            int i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }
        var tessdata = Opt("--tessdata");
        var replay = Opt("--replay");
        bool ownRotation = args.Contains("--own-rotation");

        var log = new System.Text.StringBuilder();
        log.AppendLine($"Jack Save as Word {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
        log.AppendLine($"source: {input}");
        IPageSource src;
        try
        {
            if (replay != null)
            {
                var dir = File.Exists(Path.Combine(replay, "meta.json")) ? replay : Path.Combine(replay, Path.GetFileNameWithoutExtension(input));
                src = new ReplayPageSource(dir, useMacRotation: !ownRotation);
                log.AppendLine($"replay: {dir}{(ownRotation ? " (own rotation)" : "")}");
            }
            else src = OpenWindows(input, tessdata);
        }
        catch (Exception e)
        {
            Console.WriteLine(log + $"FAILED: {Root(e)}");
            return 1;
        }

        int code;
        using (src)
        {
            var sw = Stopwatch.StartNew();
            try
            {
                var title = Path.GetFileNameWithoutExtension(input);
                var r = WordExportEngine.Export(src, Path.GetFullPath(output), title);
                if (src is ReplayPageSource rp0) rp0.CheckLetterhead(WordExportEngine.LastLetterheadPixels);
                log.AppendLine($"OK in {sw.Elapsed.TotalSeconds:F1}s → {output}");
                log.AppendLine(r.Summary);
                foreach (var d in r.Debug) log.AppendLine(d);
                code = 0;
            }
            catch (WordExportEngine.ExportException e) when (e.Kind == WordExportEngine.ErrorKind.Refused)
            {
                log.AppendLine($"REFUSED: {e.Message}");
                code = 3;
            }
            catch (Exception e)
            {
                log.AppendLine($"FAILED: {Root(e)}");
                code = 1;
            }
            if (src is ReplayPageSource rp)
            {
                log.AppendLine($"replay checks: line order {rp.SortChecks - rp.SortMismatches}/{rp.SortChecks} match the Mac, {rp.Warnings.Count} warning(s)");
                foreach (var w in rp.Warnings) log.AppendLine("replay warning: " + w);
            }
            foreach (var w in WindowsWarnings(src)) log.AppendLine("warning: " + w);
        }
        Console.Write(log.ToString());
        return code;
    }

    // Kept out of Main so a replay run never touches the Windows-only types.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static IPageSource OpenWindows(string input, string? tessdata) => new Jack.Core.Windows.WindowsPageSource(input, tessdata);

    [MethodImpl(MethodImplOptions.NoInlining)]
    static IEnumerable<string> WindowsWarnings(IPageSource src) =>
        src is Jack.Core.Windows.WindowsPageSource w ? w.Warnings : Array.Empty<string>();

    static string Root(Exception e)
    {
        var root = e;
        while (root.InnerException != null) root = root.InnerException;
        return root == e ? e.Message : $"{e.Message} ({root.GetType().Name}: {root.Message})";
    }
}
