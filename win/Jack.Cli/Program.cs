// Jack (Windows) command line.
//   Jack word <in.pdf> <out.docx> [--tessdata DIR] [--replay DIR] [--own-rotation]
//   Jack ocr <in.pdf> [<out.pdf>] [--tessdata DIR]     make a searchable copy; without <out.pdf>
//                                                      it goes to "<name> (searchable).pdf" beside it
//   Jack text <in.pdf>                                 print each page's text as PDFium extracts it
//                                                      (pages separated by a form feed line)
// Exit 0 = wrote the output, 3 = refused (a line "REFUSED: <reason>"), anything else = failed.
// For ocr, "refused" means there was nothing to do: every page already has text, or no words
// were found. Nothing is ever written over an existing file, and the input is never written.
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
        string? Opt(string name)
        {
            int i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }
        if (args.Length >= 2 && args[0] == "ocr")
            return Ocr(args[1], args.Length >= 3 && !args[2].StartsWith("--") ? args[2] : null, Opt("--tessdata"));
        if (args.Length == 2 && args[0] == "text")
            return Text(args[1]);
        if (args.Length < 3 || args[0] != "word")
        {
            Console.Error.WriteLine("usage: Jack word <in.pdf> <out.docx> [--tessdata DIR] [--replay DIR] [--own-rotation]");
            Console.Error.WriteLine("       Jack ocr <in.pdf> [<out.pdf>] [--tessdata DIR]");
            Console.Error.WriteLine("       Jack text <in.pdf>");
            return 2;
        }
        string input = args[1], output = args[2];
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

    [MethodImpl(MethodImplOptions.NoInlining)]
    static int Ocr(string input, string? output, string? tessdata)
    {
        output ??= Jack.Core.Searchable.SearchableEngine.OutputPath(input);
        var log = new System.Text.StringBuilder();
        log.AppendLine($"Jack Make Searchable {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
        log.AppendLine($"source: {input}");
        int code;
        var sw = Stopwatch.StartNew();
        try
        {
            var r = Jack.Core.Searchable.SearchableEngine.Make(input, output, tessdata);
            log.AppendLine($"OK in {sw.Elapsed.TotalSeconds:F1}s → {output}");
            log.AppendLine(r.Summary);
            foreach (var (p, why) in r.LeftAlone) log.AppendLine($"p{p + 1} left as it was: {why}");
            foreach (var d in r.Debug) log.AppendLine(d);
            code = 0;
        }
        catch (Jack.Core.Searchable.SearchableEngine.SearchableException e)
            when (e.Kind is Jack.Core.Searchable.SearchableEngine.ErrorKind.NothingToDo or Jack.Core.Searchable.SearchableEngine.ErrorKind.NoText)
        {
            log.AppendLine($"REFUSED: {e.Message}");
            code = 3;
        }
        catch (Exception e)
        {
            log.AppendLine($"FAILED: {Root(e)}");
            code = 1;
        }
        Console.Write(log.ToString());
        return code;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static int Text(string input)
    {
        try
        {
            var pages = Jack.Core.Searchable.SearchableEngine.PageTexts(input);
            for (int i = 0; i < pages.Count; i++)
            {
                if (i > 0) Console.Write("\n\f\n");
                Console.Write(pages[i]);
            }
            Console.WriteLine();
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"FAILED: {Root(e)}");
            return 1;
        }
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
