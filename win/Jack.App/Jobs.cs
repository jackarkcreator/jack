// What the card shows and the one worker that does the work. One card per kind of work (Save as
// Word, Make Searchable, photos); files are done one after another, across all cards, because
// OCR is heavy. Failed, refused and stopped jobs never leave a file behind.
using System.Diagnostics;
using Jack.Core.Searchable;
using Jack.Core.Windows;
using Jack.Core.Word;

namespace Jack.App;

internal enum Kind { Word, Searchable, Photos }

internal enum JobState { Waiting, Working, Done, Refused, Failed, Stopped, NothingToDo }

internal sealed class Job
{
    public readonly Kind Kind;
    public readonly string[] Inputs;
    public volatile JobState State = JobState.Waiting;
    public int Page, Pages;                 // progress: pages read so far, page count (0 = not known yet)
    public DateTime Started, FirstPageAt;   // for the time-left estimate
    public string? Output;
    public bool OnDesktop;                  // the PDF's folder could not be written to
    public string Message = "";             // refusal / failure reason
    public string CopyText = "";            // refused Save as Word: every word, for Copy Text
    public readonly List<string> Notes = new();   // done: extra lines (missing pages, pages left alone, skipped photos)
    public string? Warning;                 // done: a line shown in orange
    public int Uncertain = -1, Signatures, ScannedPages;

    public Job(Kind kind, string[] inputs) { Kind = kind; Inputs = inputs; }
    public string Input => Inputs[0];
    public bool Finished => State >= JobState.Done;
    public string Name => Kind == Kind.Photos
        ? (Inputs.Length == 1 ? "1 photo" : $"{Inputs.Length} photos")
        : System.IO.Path.GetFileName(State == JobState.Done && Output != null ? Output : Input);
}

internal sealed class Batch
{
    public readonly Kind Kind;
    public readonly List<Job> Jobs = new();
    public volatile bool StopRequested;
    public Batch(Kind kind) { Kind = kind; }
    public bool Running => Jobs.Any(j => !j.Finished);
}

internal static class Runner
{
    static readonly System.Collections.Concurrent.BlockingCollection<(Batch, Job)> queue = new();
    public static event Action<Batch>? Changed;           // raised on the worker thread
    public static string Tessdata => System.IO.Path.Combine(AppContext.BaseDirectory, "tessdata");
    static volatile int busy;
    public static bool Idle => busy == 0 && queue.Count == 0;

    public static void Start()
    {
        new Thread(() =>
        {
            foreach (var (b, j) in queue.GetConsumingEnumerable())
            {
                Interlocked.Increment(ref busy);
                try { Run(b, j); }
                catch (Exception e) { j.State = JobState.Failed; j.Message = "Something went wrong."; Log.Write($"job crashed: {e}"); }
                finally { Interlocked.Decrement(ref busy); }
                Changed?.Invoke(b);
            }
        }) { IsBackground = true, Name = "Jack worker" }.Start();
    }

    public static void Enqueue(Batch b, Job j) => queue.Add((b, j));

    static void Run(Batch b, Job j)
    {
        if (b.StopRequested || j.State != JobState.Waiting) { if (!j.Finished) j.State = JobState.Stopped; return; }
        j.State = JobState.Working;
        j.Started = DateTime.Now;
        Changed?.Invoke(b);
        Log.Write($"{j.Kind} start: {System.IO.Path.GetFileName(j.Input)}");
        void Progress(int i, int n)
        {
            if (i >= 1 && j.Page == 0) j.FirstPageAt = DateTime.Now;
            j.Page = i; j.Pages = n;
            Changed?.Invoke(b);
        }
        bool Cancelled() => b.StopRequested;
        try
        {
            switch (j.Kind)
            {
                case Kind.Word: Word(j, Progress, Cancelled); break;
                case Kind.Searchable: Searchable(j, Progress, Cancelled); break;
                case Kind.Photos: Photos(j, Cancelled); break;
            }
            // Stop pressed while the last step finished: nothing is kept.
            if (b.StopRequested && j.State == JobState.Done) { TryDelete(j.Output); j.State = JobState.Stopped; }
        }
        catch (OperationCanceledException) { j.State = JobState.Stopped; }
        catch (PdfOpenException e) when (e.NeedsPassword) { Fail(j, "This PDF is locked with a password. Remove the password first."); }
        catch (PdfOpenException) { Fail(j, "Jack couldn’t read this PDF."); }
        catch (Exception e) { Fail(j, j.Kind == Kind.Photos ? e.Message : "Jack couldn’t read this PDF."); Log.Write($"{j.Kind} failed: {e.Message}"); }
        Log.Write($"{j.Kind} {j.State}: {System.IO.Path.GetFileName(j.Input)}");
    }

    static void Fail(Job j, string why) { j.State = JobState.Failed; j.Message = why; }

    static void Word(Job j, Action<int, int> progress, Func<bool> cancelled)
    {
        var target = WordExportEngine.OutputPath(j.Input);
        if (!Writable(System.IO.Path.GetDirectoryName(target)!))
        {
            j.OnDesktop = true;
            target = WordExportEngine.OutputPath(System.IO.Path.Combine(Desktop, System.IO.Path.GetFileName(j.Input)));
        }
        using var src = new WindowsPageSource(j.Input, Directory.Exists(Tessdata) ? Tessdata : null);
        j.Pages = src.PageCount;
        try
        {
            var r = WordExportEngine.Export(src, target, System.IO.Path.GetFileNameWithoutExtension(j.Input), null, progress, cancelled);
            j.Output = target;
            j.State = JobState.Done;
            j.Pages = r.Pages; j.ScannedPages = r.ScannedPages;
            j.Uncertain = r.UncertainWords; j.Signatures = r.SignaturePlaceholders;
            if (r.MissingPages is { } m)
                j.Warning = $"Pages {m.Lower}–{m.Upper} aren’t in this PDF (the footers say {m.Upper}). Get them before relying on it.";
        }
        catch (WordExportEngine.ExportException e)
        {
            TryDelete(target);
            switch (e.Kind)
            {
                case WordExportEngine.ErrorKind.Cancelled: j.State = JobState.Stopped; break;
                case WordExportEngine.ErrorKind.Refused: j.State = JobState.Refused; j.Message = e.Message; j.CopyText = e.Text; break;
                default: Fail(j, e.Message); break;
            }
        }
    }

    static void Searchable(Job j, Action<int, int> progress, Func<bool> cancelled)
    {
        var target = SearchableEngine.OutputPath(j.Input);
        if (!Writable(System.IO.Path.GetDirectoryName(target)!))
        {
            j.OnDesktop = true;
            target = SearchableEngine.OutputPath(System.IO.Path.Combine(Desktop, System.IO.Path.GetFileName(j.Input)));
        }
        try
        {
            var r = SearchableEngine.Make(j.Input, target, Directory.Exists(Tessdata) ? Tessdata : null, progress, cancelled);
            j.Output = target;
            j.State = JobState.Done;
            j.Pages = r.Pages;
            int had = r.LeftAlone.Count(p => p.Why == "has text"), rotated = r.LeftAlone.Count(p => p.Why.StartsWith("rotated")),
                empty = r.LeftAlone.Count - had - rotated;
            j.Notes.Add($"{Plural(r.Recognized.Count, "page")} made searchable · every word checked back");
            if (had > 0) j.Notes.Add($"{Plural(had, "page")} already had text, left as {(had == 1 ? "it was" : "they were")}");
            if (rotated > 0) j.Notes.Add($"{Plural(rotated, "turned page")} left as {(rotated == 1 ? "it was" : "they were")} (not supported yet)");
            if (empty > 0) j.Notes.Add($"{Plural(empty, "page")} with no words found");
        }
        catch (SearchableEngine.SearchableException e)
        {
            switch (e.Kind)
            {
                case SearchableEngine.ErrorKind.Cancelled: j.State = JobState.Stopped; break;
                case SearchableEngine.ErrorKind.NothingToDo: j.State = JobState.NothingToDo; j.Message = "Every page already has text, so there was nothing to add."; break;
                case SearchableEngine.ErrorKind.NoText: j.State = JobState.Refused; j.Message = e.Message; break;
                default: Fail(j, e.Message); break;
            }
        }
    }

    static void Photos(Job j, Func<bool> cancelled)
    {
        var r = PhotosToPdf.Make(j.Inputs, Writable(Desktop) ? null : System.IO.Path.GetTempPath(), cancelled);
        j.Output = r.Path;
        j.Pages = r.Pages;
        j.State = JobState.Done;
        if (r.Skipped.Count > 0) j.Warning = $"Skipped (couldn’t be read): {string.Join(", ", r.Skipped)}";
    }

    public static string Desktop => Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);

    static bool Writable(string dir)
    {
        try
        {
            var probe = System.IO.Path.Combine(dir, $".jack-{Guid.NewGuid():N}.tmp");
            using (File.Create(probe, 1, FileOptions.DeleteOnClose)) { }
            return true;
        }
        catch { return false; }
    }

    static void TryDelete(string? path) { try { if (path != null && File.Exists(path)) File.Delete(path); } catch { } }

    public static string Plural(int n, string word) => $"{n} {word}{(n == 1 ? "" : "s")}";
}

internal static class ShellOpen
{
    public static void Open(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception e) { Log.Write("open: " + e.Message); }
    }

    /// Opens each folder with the given files selected (one Explorer window per folder).
    public static void ShowInFolder(IEnumerable<string> files)
    {
        foreach (var g in files.Where(File.Exists).GroupBy(f => System.IO.Path.GetDirectoryName(f)!, StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                var dir = Native.ILCreateFromPathW(g.Key);
                var items = g.Select(Native.ILCreateFromPathW).Where(p => p != IntPtr.Zero).ToArray();
                try { Native.SHOpenFolderAndSelectItems(dir, (uint)items.Length, items, 0); }
                finally { foreach (var p in items.Append(dir)) Native.ILFree(p); }
            }
            catch (Exception e) { Log.Write("show in folder: " + e.Message); }
        }
    }
}

internal static class Native
{
    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    public static extern IntPtr ILCreateFromPathW(string path);
    [System.Runtime.InteropServices.DllImport("shell32.dll")]
    public static extern void ILFree(IntPtr pidl);
    [System.Runtime.InteropServices.DllImport("shell32.dll")]
    public static extern int SHOpenFolderAndSelectItems(IntPtr folder, uint count, IntPtr[] items, uint flags);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hwnd, int index);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    public const int GWL_EXSTYLE = -20, WS_EX_TOOLWINDOW = 0x80;
}
