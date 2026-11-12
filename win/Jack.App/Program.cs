// Jack for Windows: the tray app.
//   Jack.exe                         start (or, when running, open the drop window)
//   Jack.exe --tray                  start quietly in the tray (autostart)
//   Jack.exe --to-word <pdf>...      Save as Word, one card for the whole selection
//   Jack.exe --searchable <pdf>...   make searchable copies
//   Jack.exe --photos <image>...     photos to one PDF on the Desktop
//   Jack.exe --drop [<file>...]      open the drop window (with files staged)
//   Jack.exe --quit                  finish what is running, then exit
//   Jack.exe --register [--autostart] | --unregister | --status    Explorer verbs (this user)
// Explorer starts one Jack.exe per selected file; the first becomes the app, the others hand
// their file over (Instance) and the app gathers files arriving within 0.4 s into one card.
using System.Windows;
using System.Windows.Threading;
using WinForms = System.Windows.Forms;

namespace Jack.App;

internal static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        if (args.Contains("--register"))
        {
            ShellVerbs.Register(Environment.ProcessPath!);
            if (args.Contains("--autostart")) ShellVerbs.SetAutostart(Environment.ProcessPath!);
            Console.WriteLine(string.Join(Environment.NewLine, ShellVerbs.Describe()));
            return 0;
        }
        if (args.Contains("--unregister")) { ShellVerbs.Unregister(); Console.WriteLine(string.Join(Environment.NewLine, ShellVerbs.Describe())); return 0; }
        if (args.Contains("--status")) { Console.WriteLine(string.Join(Environment.NewLine, ShellVerbs.Describe())); return 0; }

        var request = Parse(args);
        using var primary = Instance.TryBecomePrimary();
        if (primary == null)
        {
            if (request == null && args.Contains("--tray")) return 0;          // already running
            var ok = Instance.Forward(request ?? new Request("drop", Array.Empty<string>()), TimeSpan.FromSeconds(15));
            if (!ok) Log.Write("could not reach the running Jack");
            return ok ? 0 : 1;
        }

        Log.Write($"start {string.Join(' ', args.Where(a => a.StartsWith("--")))}");
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.DispatcherUnhandledException += (_, e) => { Log.Write("ui error: " + e.Exception); e.Handled = true; };
        var c = new Controller(app);
        app.Dispatcher.BeginInvoke(() =>
        {
            c.Start();
            if (request != null) c.Handle(request);
            else if (!args.Contains("--tray")) c.Handle(new Request("drop", Array.Empty<string>()));
        });
        app.Run();
        GC.KeepAlive(primary);
        return 0;
    }

    static Request? Parse(string[] args)
    {
        string? verb = null;
        foreach (var a in args)
            verb = a switch
            {
                "--to-word" => "word",
                "--searchable" => "searchable",
                "--photos" => "photos",
                "--drop" => "drop",
                "--quit" => "quit",
                _ => verb,
            };
        if (verb == null) return null;
        var files = args.Where(a => !a.StartsWith("--")).Select(a => { try { return Path.GetFullPath(a); } catch { return ""; } })
            .Where(a => a.Length > 0).ToArray();
        return new Request(verb, files);
    }
}

internal sealed class Controller
{
    public static volatile bool ShuttingDown;
    readonly Application app;
    readonly Dictionary<Kind, (Batch Batch, Card Card)> cards = new();
    readonly Dictionary<Kind, List<string>> pending = new();
    readonly DispatcherTimer gather;
    DropWindow? drop;
    WinForms.NotifyIcon? tray;
    bool quitWhenIdle;

    public Controller(Application app)
    {
        this.app = app;
        gather = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        gather.Tick += (_, _) => { gather.Stop(); Flush(); };
    }

    public void Start()
    {
        Runner.Changed += b => app.Dispatcher.BeginInvoke(() => OnChanged(b));
        Runner.Start();
        Instance.Serve(r => app.Dispatcher.BeginInvoke(() => Handle(r)), CancellationToken.None);
        tray = Tray();
    }

    public void Handle(Request r)
    {
        if (Instance.Validate(r) is not Request v) { Log.Write($"ignored request '{r.Verb}'"); return; }
        switch (v.Verb)
        {
            case "drop":
            case "show":
                (drop ??= new DropWindow(Run)).ShowNear(v.Files.Length > 0 ? v.Files : null);
                break;
            case "quit":
                quitWhenIdle = true;
                CheckQuit();
                break;
            default:
                var kind = v.Verb switch { "word" => Kind.Word, "searchable" => Kind.Searchable, _ => Kind.Photos };
                if (!pending.TryGetValue(kind, out var list)) pending[kind] = list = new List<string>();
                list.AddRange(v.Files);
                gather.Stop(); gather.Start();       // gather files arriving close together
                break;
        }
    }

    void Run(Kind kind, string[] files) { pending.TryAdd(kind, new List<string>()); pending[kind].AddRange(files); Flush(); }

    void Flush()
    {
        foreach (var (kind, files) in pending.ToList())
        {
            pending.Remove(kind);
            var unique = files.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            if (unique.Count == 0) continue;
            Batch batch;
            var jobs = kind == Kind.Photos
                ? new List<Job> { new(kind, unique.OrderBy(Path.GetFileName, new NaturalComparer()).ToArray()) }
                : unique.Select(f => new Job(kind, new[] { f })).ToList();
            if (cards.TryGetValue(kind, out var open) && open.Batch.Running)
            {
                // Running: add to the same card, skipping files still waiting or working there.
                batch = open.Batch;
                var busy = batch.Jobs.Where(j => !j.Finished).SelectMany(j => j.Inputs).ToHashSet(StringComparer.OrdinalIgnoreCase);
                jobs = jobs.Where(j => !j.Inputs.Any(busy.Contains)).ToList();
                batch.Jobs.AddRange(jobs);
                open.Card.Render();
            }
            else
            {
                if (cards.TryGetValue(kind, out var old)) old.Card.Close();
                batch = new Batch(kind);
                batch.Jobs.AddRange(jobs);
                var card = new Card(batch);
                card.Closed += (_, _) => { if (cards.TryGetValue(kind, out var c) && c.Card == card) cards.Remove(kind); Restack(); CheckQuit(); };
                card.Placed = Restack;
                cards[kind] = (batch, card);
                card.Render();
                card.Show();
                Restack();
            }
            foreach (var j in jobs) Runner.Enqueue(batch, j);
            Log.Write($"{kind}: {jobs.Count} file(s) queued");
        }
        TestHooks.State(cards.Values.Select(c => c.Batch), Runner.Idle);
    }

    void OnChanged(Batch b)
    {
        foreach (var (batch, card) in cards.Values)
            if (batch == b) card.Render();
        TestHooks.State(cards.Values.Select(c => c.Batch), Runner.Idle && cards.Values.All(c => !c.Batch.Running));
        CheckQuit();
    }

    /// Cards stack upward from the bottom-right corner, oldest at the bottom.
    void Restack()
    {
        double bottom = 0;
        foreach (var (_, card) in cards.Values)
        {
            if (!card.IsVisible) continue;
            card.PlaceAt(bottom);
            bottom += card.ActualHeight - 28 + 10;   // panel height (shadow room excluded) + a 10 px gap
        }
    }

    void CheckQuit()
    {
        if (!quitWhenIdle || pending.Count > 0 || gather.IsEnabled) return;
        if (!Runner.Idle || cards.Values.Any(c => c.Batch.Running)) return;
        Quit();
    }

    void Quit()
    {
        ShuttingDown = true;
        TestHooks.State(cards.Values.Select(c => c.Batch), true);
        if (tray != null) { tray.Visible = false; tray.Dispose(); }
        foreach (var (_, card) in cards.Values.ToList()) card.Close();
        drop?.Close();
        Log.Write("quit");
        app.Shutdown();
    }

    // MARK: - Tray

    WinForms.NotifyIcon Tray()
    {
        var icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? System.Drawing.SystemIcons.Application;
        var menu = new WinForms.ContextMenuStrip();
        menu.Items.Add("Open drop window", null, (_, _) => Handle(new Request("drop", Array.Empty<string>())));
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("Convert PDFs to Word…", null, (_, _) => Pick(Kind.Word));
        menu.Items.Add("Make PDFs searchable…", null, (_, _) => Pick(Kind.Searchable));
        menu.Items.Add("Combine photos into one PDF…", null, (_, _) => Pick(Kind.Photos));
        menu.Items.Add(new WinForms.ToolStripSeparator());
        var verbs = new WinForms.ToolStripMenuItem("Show in Explorer’s right-click menu") { CheckOnClick = true };
        var autostart = new WinForms.ToolStripMenuItem("Start with Windows") { CheckOnClick = true };
        menu.Opening += (_, _) =>
        {
            var d = ShellVerbs.Describe().ToList();
            verbs.Checked = d.Take(3).All(l => !l.EndsWith("(not registered)"));
            autostart.Checked = !d.Last().EndsWith("(off)");
        };
        verbs.Click += (_, _) => { if (verbs.Checked) ShellVerbs.Register(Environment.ProcessPath!); else ShellVerbs.UnregisterVerbs(); };
        autostart.Click += (_, _) => ShellVerbs.SetAutostart(autostart.Checked ? Environment.ProcessPath! : null);
        menu.Items.Add(verbs);
        menu.Items.Add(autostart);
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("Quit Jack", null, (_, _) =>
        {
            foreach (var (_, card) in cards.Values) card.Stop();
            quitWhenIdle = true;
            CheckQuit();
        });
        var ni = new WinForms.NotifyIcon { Icon = icon, Text = "Jack", Visible = true, ContextMenuStrip = menu };
        ni.MouseClick += (_, e) => { if (e.Button == WinForms.MouseButtons.Left) Handle(new Request("drop", Array.Empty<string>())); };
        return ni;
    }

    void Pick(Kind kind)
    {
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Multiselect = true,
            Title = kind switch { Kind.Word => "Choose PDFs to convert to Word", Kind.Searchable => "Choose PDFs to make searchable", _ => "Choose photos to combine into one PDF" },
            Filter = kind == Kind.Photos ? "Photos|*.jpg;*.jpeg;*.png;*.bmp;*.gif;*.tif;*.tiff" : "PDFs|*.pdf",
        };
        if (dlg.ShowDialog() == true) Run(kind, dlg.FileNames);
    }
}
