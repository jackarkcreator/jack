// Only when JACK_APP_TEST_DIR is set (CI): every visible change of a card or the drop window is
// saved as a PNG, the state of every card is written to state.json, and any button or progress
// bar without an accessible name is listed in unnamed.txt (Narrator would read nothing for it).
// Off in normal use: nothing is written.
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Jack.App;

internal static class TestHooks
{
    public static readonly string? Dir = Environment.GetEnvironmentVariable("JACK_APP_TEST_DIR") is { Length: > 0 } d ? d : null;
    static readonly Dictionary<Window, string> last = new();
    static int seq;

    public static void Shot(Window w, string name, string signature)
    {
        if (Dir == null) return;
        if (last.TryGetValue(w, out var s) && s == signature) return;
        last[w] = signature;
        int n = Interlocked.Increment(ref seq);
        w.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, () =>
        {
            try
            {
                Directory.CreateDirectory(Dir);
                if (w.Content is not FrameworkElement root || root.ActualWidth <= 0) { last.Remove(w); return; }   // not laid out yet: next render
                double dpi = VisualTreeHelper.GetDpi(root).PixelsPerDip;
                // The panel sits inside a margin (shadow room) that offsets it when rendered: include it.
                double w = root.ActualWidth + root.Margin.Left + root.Margin.Right, h = root.ActualHeight + root.Margin.Top + root.Margin.Bottom;
                var bmp = new RenderTargetBitmap((int)Math.Ceiling(w * dpi), (int)Math.Ceiling(h * dpi), 96 * dpi, 96 * dpi, PixelFormats.Pbgra32);
                bmp.Render(root);
                var enc = new PngBitmapEncoder();
                enc.Frames.Add(BitmapFrame.Create(bmp));
                using (var f = File.Create(Path.Combine(Dir, $"{n:D3}-{name}.png"))) enc.Save(f);
                var unnamed = Walk(root).Where(e => e is Button or ProgressBar)
                    .Where(e => string.IsNullOrWhiteSpace(AutomationProperties.GetName(e)) && !(e is Button { Content: string }))
                    .Select(e => $"{n:D3}-{name}: {e.GetType().Name}").ToList();
                if (unnamed.Count > 0) File.AppendAllLines(Path.Combine(Dir, "unnamed.txt"), unnamed);
            }
            catch (Exception e) { Log.Write("test shot: " + e.Message); }
        });
    }

    static IEnumerable<DependencyObject> Walk(DependencyObject d)
    {
        yield return d;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(d); i++)
            foreach (var c in Walk(VisualTreeHelper.GetChild(d, i))) yield return c;
    }

    public static void State(IEnumerable<Batch> batches, bool idle)
    {
        if (Dir == null) return;
        try
        {
            Directory.CreateDirectory(Dir);
            var json = JsonSerializer.Serialize(new
            {
                idle,
                batches = batches.Select(b => new
                {
                    kind = b.Kind.ToString(),
                    running = b.Running,
                    jobs = b.Jobs.Select(j => new { inputs = j.Inputs, state = j.State.ToString(), output = j.Output, message = j.Message, notes = j.Notes, warning = j.Warning }),
                }),
            }, new JsonSerializerOptions { WriteIndented = true });
            var tmp = Path.Combine(Dir, "state.json.tmp");
            File.WriteAllText(tmp, json);
            File.Move(tmp, Path.Combine(Dir, "state.json"), overwrite: true);
        }
        catch (Exception e) { Log.Write("test state: " + e.Message); }
    }
}
