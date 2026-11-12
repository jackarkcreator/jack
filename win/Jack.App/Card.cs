// The corner card: one per kind of work, bottom-right of the screen it first appeared on, never
// steals focus when it appears. Mirrors the Mac card (Sources/WordConvertCard.swift):
// single-file states (working, done, refused, failed, stopped) and a list for several files.
// Esc stops while running, closes otherwise. Return = the primary button. Closes itself 60 s
// after finishing (2.5 s if everything was stopped), and waits while the pointer is over it.
// Wording is the Mac's, with "this PC" for "this Mac" and "folder" for "Finder".
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace Jack.App;

internal sealed class Card : Window
{
    public readonly Batch Batch;
    readonly System.Drawing.Rectangle workArea;     // pixels, of the screen the card first appeared on
    DispatcherTimer? closeTimer;
    public Action? Placed;                          // the controller re-stacks cards when a height changes

    public Card(Batch batch)
    {
        Batch = batch;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.Height;
        Title = "Jack";
        FontFamily = Theme.Font;
        workArea = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position).WorkingArea;
        SourceInitialized += (_, _) =>
        {
            var h = new WindowInteropHelper(this).Handle;   // keep it out of Alt+Tab
            Native.SetWindowLong(h, Native.GWL_EXSTYLE, Native.GetWindowLong(h, Native.GWL_EXSTYLE) | Native.WS_EX_TOOLWINDOW);
        };
        SizeChanged += (_, _) => Placed?.Invoke();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            if (Batch.Running) Stop(); else Close();
            e.Handled = true;
        };
        Closing += (_, e) => { if (Batch.Running && !Controller.ShuttingDown) e.Cancel = true; };
    }

    bool Single => Batch.Jobs.Count == 1;

    /// Bottom-right corner, `stackBottom` DIPs above the work area's bottom (cards stack upward).
    public void PlaceAt(double stackBottom)
    {
        var t = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var br = t.Transform(new Point(workArea.Right, workArea.Bottom));
        const double inset = 22 - 14;                  // 22 from the screen edge to the panel; 14 is shadow room
        Left = br.X - Width - inset;
        Top = br.Y - ActualHeight - inset - stackBottom;
    }

    public void Stop()
    {
        Batch.StopRequested = true;
        foreach (var j in Batch.Jobs.Where(j => j.State == JobState.Waiting)) j.State = JobState.Stopped;
        Render();
    }

    public void Render()
    {
        Width = (Single ? 352 : 380) + 28;
        var body = new StackPanel { Margin = new Thickness(16, 16, 16, 14) };
        if (Single) BuildSingle(body, Batch.Jobs[0]); else BuildList(body);
        Content = Theme.PanelBorder(body);
        AutomationProperties.SetName(this, $"Jack: {TitleText()}");
        if (!Batch.Running) ScheduleClose(); else { closeTimer?.Stop(); closeTimer = null; }
        TestHooks.Shot(this, $"card-{Batch.Kind.ToString().ToLowerInvariant()}", Signature());
    }

    // MARK: - Text

    string Noun => Batch.Kind == Kind.Photos ? "photos" : "PDF";

    string TitleText()
    {
        if (!Single)
        {
            int n = Batch.Jobs.Count, done = Batch.Jobs.Count(j => j.State == JobState.Done);
            return (Batch.Kind, Batch.Running) switch
            {
                (Kind.Word, true) => $"Converting {n} PDFs to Word",
                (Kind.Word, false) => $"{done} of {n} PDFs saved as Word",
                (Kind.Searchable, true) => $"Making {n} PDFs searchable",
                (Kind.Searchable, false) => $"{done} of {n} PDFs made searchable",
                (_, true) => "Combining photos into PDFs",
                (_, false) => $"{done} of {n} PDFs made from photos",
            };
        }
        var j = Batch.Jobs[0];
        return (Batch.Kind, j.State) switch
        {
            (_, JobState.Stopped) => "Stopped",
            (Kind.Word, JobState.Done) => "Saved as Word",
            (Kind.Word, JobState.Refused) => "Not converted",
            (Kind.Word, JobState.Failed) => "Couldn’t convert",
            (Kind.Word, _) => "Converting to Word",
            (Kind.Searchable, JobState.Done) => "Saved a searchable copy",
            (Kind.Searchable, JobState.NothingToDo) => "Already searchable",
            (Kind.Searchable, JobState.Refused) => "Not made searchable",
            (Kind.Searchable, JobState.Failed) => "Couldn’t make it searchable",
            (Kind.Searchable, _) => "Making it searchable",
            (_, JobState.Done) => "Saved as PDF",
            (_, JobState.Failed) => "Couldn’t make the PDF",
            _ => "Combining photos into a PDF",
        };
    }

    static string Where(Job j) =>
        j.OnDesktop || string.Equals(Path.GetDirectoryName(j.Output), Runner.Desktop, StringComparison.OrdinalIgnoreCase)
            ? "on your Desktop" : $"in {Path.GetFileName(Path.GetDirectoryName(j.Output))}";

    static string PagesNote(Job j)
    {
        if (j.Pages <= 0) return "";
        var s = $" · {Runner.Plural(j.Pages, "page")}";
        if (j.Kind == Kind.Word && j.ScannedPages > 0) s += j.ScannedPages >= j.Pages ? ", scanned" : $", {j.ScannedPages} scanned";
        return s;
    }

    static string Status(Job j)
    {
        if (j.Kind == Kind.Photos) return "Resizing and combining…";
        if (j.Pages == 0 || j.State == JobState.Waiting) return "Getting ready…";
        if (j.Page < j.Pages) return $"Reading page {j.Page + 1} of {j.Pages}";
        return j.Kind == Kind.Word ? "Checking every word against the PDF…" : "Writing the text layer and checking every word…";
    }

    static string TimeLeft(Job j)
    {
        if (j.Page < 1 || j.Pages <= 0 || j.Page >= j.Pages) return "";
        double per = (DateTime.Now - j.Started).TotalSeconds / j.Page, left = per * (j.Pages - j.Page);
        if (left < 10) return "a few seconds left";
        if (left < 90) return $"about {Math.Max(5, Math.Round(left / 5) * 5):F0} s left";
        return $"about {Math.Ceiling(left / 60):F0} min left";
    }

    string FooterNote => Batch.Kind switch
    {
        Kind.Word => "On this PC · Match pages · highlights on",
        Kind.Searchable => "On this PC · the original is never changed",
        _ => "On this PC · the photos are never changed",
    };

    /// What a screenshot would show, without page numbers (test hook: one PNG per real change).
    string Signature() => TitleText() + "|" + string.Join(",", Batch.Jobs.Select(j => j.State));

    // MARK: - Single file

    void BuildSingle(StackPanel body, Job j)
    {
        var glyph = j.State switch
        {
            JobState.Done => Theme.Glyph.Done,
            JobState.NothingToDo => Theme.Glyph.Info,
            JobState.Refused => Theme.Glyph.Refused,
            JobState.Failed or JobState.Stopped => Theme.Glyph.Stopped,
            _ => Batch.Kind switch { Kind.Word => Theme.Glyph.Word, Kind.Searchable => Theme.Glyph.Searchable, _ => Theme.Glyph.Photos },
        };
        string subtitle = j.State switch
        {
            JobState.Done => $"{Path.GetFileName(j.Output)} · {Where(j)}{PagesNote(j)}",
            JobState.Stopped => "Nothing was saved.",
            JobState.Refused or JobState.Failed or JobState.NothingToDo => j.Message,
            _ => j.Kind == Kind.Photos ? $"{j.Name}…" : $"{Path.GetFileName(j.Input)}{(j.Pages > 0 ? $" · {Runner.Plural(j.Pages, "page")}" : "")}…",
        };
        body.Children.Add(Header(glyph, TitleText(), subtitle, closable: j.Finished));

        if (!j.Finished)
        {
            var bar = new ProgressBar { Style = Theme.Style("Bar"), Margin = new Thickness(0, 12, 0, 0), Minimum = 0, Maximum = Math.Max(1, j.Pages) };
            if (j.Pages > 0 && j.State == JobState.Working && j.Kind != Kind.Photos) bar.Value = Math.Min(j.Page, j.Pages); else bar.IsIndeterminate = true;
            AutomationProperties.SetName(bar, "Progress");
            body.Children.Add(bar);
            var row = new DockPanel { Margin = new Thickness(0, 8, 0, 0), LastChildFill = true };
            var eta = Theme.Text(TimeLeft(j), 12, Theme.Secondary, wrap: false);
            DockPanel.SetDock(eta, Dock.Right);
            row.Children.Add(eta);
            var status = Theme.Text(Status(j), 12, Theme.Secondary);
            AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
            row.Children.Add(status);
            body.Children.Add(row);
            body.Children.Add(Footer(running: true));
            return;
        }

        var lines = new StackPanel { Margin = new Thickness(45, 10, 0, 0) };
        if (j.State == JobState.Done)
        {
            if (j.Warning != null) lines.Children.Add(Line(j.Warning, Theme.Orange));
            if (j.OnDesktop) lines.Children.Add(Line(j.Kind == Kind.Word
                ? "The PDF’s folder can’t be written to, so the Word file went to your Desktop."
                : "The PDF’s folder can’t be written to, so the copy went to your Desktop."));
            if (j.Kind == Kind.Word)
            {
                if (j.Uncertain > 0) lines.Children.Add(Swatch($"{Runner.Plural(j.Uncertain, "word")} to double-check, highlighted in Word"));
                else if (j.Uncertain == 0) lines.Children.Add(Check("Every word matched a second reading"));
                if (j.Signatures > 0) lines.Children.Add(Line($"{Runner.Plural(j.Signatures, "signature")} left as a placeholder line"));
            }
            foreach (var n in j.Notes) lines.Children.Add(n == j.Notes[0] && j.Kind == Kind.Searchable ? Check(n) : Line(n));
        }
        if (lines.Children.Count > 0) body.Children.Add(lines);

        var buttons = Buttons();
        switch (j.State)
        {
            case JobState.Done:
                buttons.Children.Add(Theme.Button("Show in folder", "Btn", () => { ShellOpen.ShowInFolder(new[] { j.Output! }); Close(); }));
                buttons.Children.Add(Primary(j.Kind == Kind.Word ? "Open in Word" : "Open", () => { ShellOpen.Open(j.Output!); Close(); }));
                break;
            case JobState.Refused when j.Kind == Kind.Word:
                buttons.Children.Add(Theme.Button("Open PDF", "Btn", () => { ShellOpen.Open(j.Input); Close(); }));
                buttons.Children.Add(Primary("Copy Text", () => { CopyText(j); Close(); }));
                break;
            case JobState.Stopped:
                break;
            default:
                buttons.Children.Add(Primary("Close", Close));
                break;
        }
        if (buttons.Children.Count > 0) body.Children.Add(buttons);
    }

    // MARK: - Several files

    void BuildList(StackPanel body)
    {
        var js = Batch.Jobs;
        var counts = new List<string>();
        void Count(Func<Job, bool> p, string word) { int n = js.Count(p); if (n > 0) counts.Add($"{n} {word}"); }
        Count(j => j.State == JobState.Done, "done");
        Count(j => j.State == JobState.Working, "working");
        Count(j => j.State == JobState.Waiting, "waiting");
        Count(j => j.State == JobState.NothingToDo, "already searchable");
        Count(j => j.State is JobState.Refused or JobState.Failed, Batch.Kind == Kind.Searchable ? "not made searchable" : "not converted");
        Count(j => j.State == JobState.Stopped, "stopped");
        var glyph = Batch.Kind switch { Kind.Word => Theme.Glyph.Word, Kind.Searchable => Theme.Glyph.Searchable, _ => Theme.Glyph.Photos };
        body.Children.Add(Header(glyph, TitleText(), string.Join(" · ", counts), closable: !Batch.Running));

        var list = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
        foreach (var j in js) list.Children.Add(Row(j));
        body.Children.Add(list);

        if (Batch.Running) { body.Children.Add(Footer(running: true, stopLabel: "Stop all")); return; }
        var buttons = Buttons();
        var outs = js.Where(j => j.State == JobState.Done && j.Output != null).Select(j => j.Output!).ToList();
        buttons.Children.Add(outs.Count > 0
            ? Primary("Show in folder", () => { ShellOpen.ShowInFolder(outs); Close(); })
            : Primary("Close", Close));
        body.Children.Add(buttons);
    }

    FrameworkElement Row(Job j)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 4, 0, 4) };
        var row = new DockPanel { LastChildFill = true };
        var icon = Theme.Icon(j.State switch
        {
            JobState.Done => Theme.RowIcon.Done,
            JobState.Working => Theme.RowIcon.Working,
            JobState.Refused or JobState.Failed => Theme.RowIcon.Problem,
            _ => Theme.RowIcon.Waiting,
        });
        icon.Margin = new Thickness(0, 1, 9, 0);
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        FrameworkElement right = j.State switch
        {
            JobState.Done => Theme.Button("Open", "Link", () => ShellOpen.Open(j.Output!), $"Open {Path.GetFileName(j.Output)}"),
            JobState.Working => Theme.Text(j.Pages > 0 && j.Page < j.Pages ? $"page {j.Page + 1} of {j.Pages}" : j.Pages > 0 ? "checking" : "starting", 12, Theme.Secondary, wrap: false),
            JobState.Waiting => Theme.Text("waiting", 12, Theme.Secondary, wrap: false),
            JobState.Stopped => Theme.Text("stopped", 12, Theme.Secondary, wrap: false),
            JobState.NothingToDo => Theme.Text("already searchable", 12, Theme.Secondary, wrap: false),
            _ => Theme.Text(Batch.Kind == Kind.Searchable ? "not made searchable" : "not converted", 12, Theme.Orange, wrap: false),
        };
        right.Margin = new Thickness(10, 0, 0, 0);
        right.VerticalAlignment = VerticalAlignment.Top;
        DockPanel.SetDock(right, Dock.Right);
        row.Children.Add(right);
        row.Children.Add(Theme.Text(j.Name, 12.5, Theme.Ink, j.State == JobState.Working ? FontWeights.SemiBold : FontWeights.Normal));
        panel.Children.Add(row);
        if (j.State == JobState.Working && j.Kind != Kind.Photos)
        {
            var bar = new ProgressBar { Style = Theme.Style("Bar"), Margin = new Thickness(25, 6, 0, 0), Minimum = 0, Maximum = Math.Max(1, j.Pages) };
            if (j.Pages > 0) bar.Value = Math.Min(j.Page, j.Pages); else bar.IsIndeterminate = true;
            AutomationProperties.SetName(bar, $"Progress of {j.Name}");
            panel.Children.Add(bar);
        }
        if (j.State is JobState.Refused or JobState.Failed)
        {
            var why = Theme.Text(j.Message, 11.5, Theme.Secondary);
            why.Margin = new Thickness(25, 3, 0, 0);
            panel.Children.Add(why);
            if (j.Kind == Kind.Word && j.State == JobState.Refused && j.CopyText.Length > 0)
            {
                var copy = Theme.Button("Copy Text", "Link", () => CopyText(j), $"Copy the text of {j.Name}");
                copy.Margin = new Thickness(25, 3, 0, 0);
                copy.HorizontalAlignment = HorizontalAlignment.Left;
                panel.Children.Add(copy);
            }
        }
        return panel;
    }

    // MARK: - Pieces

    FrameworkElement Header(Theme.Glyph glyph, string title, string subtitle, bool closable)
    {
        var g = new DockPanel { LastChildFill = true };
        var tile = Theme.Tile(glyph);
        tile.Margin = new Thickness(0, 0, 11, 0);
        DockPanel.SetDock(tile, Dock.Left);
        g.Children.Add(tile);
        if (closable)
        {
            var x = new Button { Style = Theme.Style("Close"), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(8, -6, -6, 0) };
            AutomationProperties.SetName(x, "Close");
            x.Click += (_, _) => Close();
            DockPanel.SetDock(x, Dock.Right);
            g.Children.Add(x);
        }
        var text = new StackPanel { VerticalAlignment = subtitle.Length > 60 ? VerticalAlignment.Top : VerticalAlignment.Center };
        var t = Theme.Text(title, 14, Theme.Ink, FontWeights.SemiBold);
        AutomationProperties.SetHeadingLevel(t, AutomationHeadingLevel.Level1);
        text.Children.Add(t);
        if (subtitle.Length > 0)
        {
            var s = Theme.Text(subtitle, 12, Theme.Secondary);
            s.Margin = new Thickness(0, 2, 0, 0);
            AutomationProperties.SetLiveSetting(s, AutomationLiveSetting.Polite);
            text.Children.Add(s);
        }
        g.Children.Add(text);
        return g;
    }

    FrameworkElement Footer(bool running, string stopLabel = "Stop")
    {
        var row = new DockPanel { Margin = new Thickness(0, 12, 0, 0), LastChildFill = true };
        var stop = Theme.Button(stopLabel, "Btn", Stop);
        stop.IsCancel = false;
        DockPanel.SetDock(stop, Dock.Right);
        row.Children.Add(stop);
        var note = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        note.Children.Add(Theme.Lock());
        note.Children.Add(Theme.Text(FooterNote, 11.5, Theme.Secondary));
        row.Children.Add(note);
        return row;
    }

    static StackPanel Buttons() => new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };

    Button Primary(string label, Action click)
    {
        var b = Theme.Button(label, "Primary", click);
        b.IsDefault = true;
        return b;
    }

    static FrameworkElement Line(string s, Brush? color = null)
    {
        var t = Theme.Text(s, 12, color ?? Theme.Secondary);
        t.Margin = new Thickness(0, 2, 0, 2);
        return t;
    }

    static FrameworkElement Swatch(string s)
    {
        var p = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
        var sw = new Border { Width = 14, Height = 10, Background = Theme.Highlight, CornerRadius = new CornerRadius(2), Margin = new Thickness(0, 3, 7, 0), VerticalAlignment = VerticalAlignment.Top };
        DockPanel.SetDock(sw, Dock.Left);
        p.Children.Add(sw);
        p.Children.Add(Theme.Text(s, 12, Theme.Ink));
        return p;
    }

    static FrameworkElement Check(string s)
    {
        var p = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
        var c = new System.Windows.Shapes.Path
        {
            Data = Geometry.Parse("M1,6 L4.5,9.5 L11,2.5"), Stroke = Theme.Teal, StrokeThickness = 1.8, Width = 14, Height = 12,
            Margin = new Thickness(0, 2, 7, 0), VerticalAlignment = VerticalAlignment.Top,
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        };
        DockPanel.SetDock(c, Dock.Left);
        p.Children.Add(c);
        p.Children.Add(Theme.Text(s, 12, Theme.Ink));
        return p;
    }

    static void CopyText(Job j)
    {
        try { Clipboard.SetText(j.CopyText); } catch (Exception e) { Log.Write("clipboard: " + e.Message); }
    }

    void ScheduleClose()
    {
        if (closeTimer != null) return;
        bool allStopped = Batch.Jobs.All(j => j.State == JobState.Stopped);
        closeTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(allStopped ? 2.5 : 60) };
        closeTimer.Tick += (_, _) =>
        {
            if (IsMouseOver) { closeTimer.Interval = TimeSpan.FromSeconds(10); return; }
            closeTimer.Stop();
            Close();
        };
        closeTimer.Start();
    }
}
