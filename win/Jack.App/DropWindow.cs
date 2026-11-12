// The drop window: opened from the tray icon (or by starting Jack again). Windows has no public
// way to notice a drag starting anywhere on screen, so unlike the Mac shelf it does not pop up by
// itself during a drag; it sits bottom-right until used or dismissed.
//   1 PDF       → "Convert to Word" | "Make searchable"
//   2+ PDFs     → "Convert each to Word" | "Make each searchable"
//   photos      → "Combine N photos into one PDF" (saved to the Desktop)
//   anything else → a plain message, nothing happens
// Files can also be chosen with "Choose files…" (keyboard and Narrator users): the zones then
// become buttons. Esc closes. Dropping hides it and hands the files to the controller.
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace Jack.App;

internal sealed class DropWindow : Window
{
    readonly Action<Kind, string[]> run;
    string[]? staged;           // files chosen or being dragged
    bool dragging;

    public DropWindow(Action<Kind, string[]> run)
    {
        this.run = run;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.Height;
        Width = 352 + 28;
        Title = "Jack";
        FontFamily = Theme.Font;
        AllowDrop = true;
        AutomationProperties.SetName(this, "Jack drop window");
        SourceInitialized += (_, _) =>
        {
            var h = new WindowInteropHelper(this).Handle;
            Native.SetWindowLong(h, Native.GWL_EXSTYLE, Native.GetWindowLong(h, Native.GWL_EXSTYLE) | Native.WS_EX_TOOLWINDOW);
        };
        SizeChanged += (_, _) => Place();
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { Hide(); e.Handled = true; } };
        DragEnter += (_, e) => { dragging = true; Stage(Files(e)); e.Effects = DragDropEffects.Copy; e.Handled = true; };
        DragOver += (_, e) => { e.Effects = DragDropEffects.Copy; e.Handled = true; };
        DragLeave += (_, e) =>
        {
            // DragLeave also fires when moving between child elements: only reset when the pointer left the window.
            var p = e.GetPosition(this);
            if (p.X < 0 || p.Y < 0 || p.X > ActualWidth || p.Y > ActualHeight) { dragging = false; Stage(null); }
        };
        Drop += (_, e) => { dragging = false; Stage(null); };   // dropped outside a zone: nothing happens
        Render();
    }

    static string[]? Files(DragEventArgs e) => e.Data.GetDataPresent(DataFormats.FileDrop) ? e.Data.GetData(DataFormats.FileDrop) as string[] : null;

    public void ShowNear(string[]? files = null)
    {
        Stage(files);
        if (!IsVisible) Show();
        Activate();
        Place();
    }

    public void Stage(string[]? files) { staged = files is { Length: > 0 } ? files : null; Render(); }

    void Place()
    {
        var wa = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position).WorkingArea;
        var t = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var br = t.Transform(new Point(wa.Right, wa.Bottom));
        Left = br.X - Width - 8;
        Top = br.Y - ActualHeight - 8;
    }

    // MARK: - What the files are

    sealed record Offer(Kind Kind, Theme.Glyph Glyph, string Action, string Detail, string[] Files);

    (string Heading, List<Offer> Offers, string? Message, string? MessageDetail) Classify(string[] files)
    {
        if (files.Any(Directory.Exists)) return ("", new(), "Folders aren’t supported yet", "Open the folder and select the PDFs inside");
        var pdfs = files.Where(f => Path.GetExtension(f).Equals(".pdf", StringComparison.OrdinalIgnoreCase)).ToArray();
        var photos = files.Where(PhotosToPdf.IsPhoto).ToArray();
        if (pdfs.Length == files.Length)
        {
            bool one = pdfs.Length == 1;
            return (one ? Path.GetFileName(pdfs[0]) : $"{pdfs.Length} PDFs", new()
            {
                new(Kind.Word, Theme.Glyph.Word, one ? "Convert to Word" : "Convert each to Word",
                    one ? ".docx saved beside it" : $"{pdfs.Length} .docx files, beside each", pdfs),
                new(Kind.Searchable, Theme.Glyph.Searchable, one ? "Make searchable" : "Make each searchable",
                    one ? "a searchable copy beside it" : $"{pdfs.Length} searchable copies, beside each", pdfs),
            }, null, null);
        }
        if (photos.Length == files.Length)
            return ("", new()
            {
                new(Kind.Photos, Theme.Glyph.Photos, photos.Length == 1 ? "Turn 1 photo into a PDF" : $"Combine {photos.Length} photos into one PDF",
                    "Saved to your Desktop", photos),
            }, null, null);
        if (pdfs.Length > 0 && photos.Length > 0) return ("", new(), "One kind at a time", "Drop the PDFs or the photos, not both together");
        return ("", new(), "Jack takes PDFs or photos", "These files aren’t PDFs or photos");
    }

    // MARK: - Drawing

    void Render()
    {
        var body = new StackPanel { Margin = new Thickness(16, 12, 16, 12) };
        var top = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, 10) };
        var x = new Button { Style = Theme.Style("Close"), Margin = new Thickness(8, 0, -6, 0) };
        AutomationProperties.SetName(x, "Close");
        x.Click += (_, _) => Hide();
        DockPanel.SetDock(x, Dock.Right);
        top.Children.Add(x);

        if (staged == null)
        {
            top.Children.Add(Theme.Text("Jack", 12, Theme.Heading, FontWeights.SemiBold));
            body.Children.Add(top);
            var zone = Zone(Theme.Glyph.Searchable, "Drop PDFs or photos here", "Convert to Word · make searchable · photos to one PDF", null, wide: true);
            zone.IsEnabled = true;
            AutomationProperties.SetName(zone, "Drop PDFs or photos here, or press to choose files");
            zone.Click += (_, _) => Choose();
            body.Children.Add(zone);
            var choose = Theme.Button("Choose files…", "Link", Choose);
            choose.HorizontalAlignment = HorizontalAlignment.Center;
            choose.Margin = new Thickness(0, 10, 0, 0);
            body.Children.Add(choose);
        }
        else
        {
            var (heading, offers, message, detail) = Classify(staged);
            var h = Theme.Text(heading.Length > 0 ? heading : " ", 12, Theme.Heading, FontWeights.SemiBold);
            h.TextAlignment = TextAlignment.Center;
            top.Children.Add(h);
            body.Children.Add(top);
            var zones = new UniformGrid { Rows = 1, Columns = Math.Max(1, offers.Count) };
            if (offers.Count == 0)
            {
                var z = Zone(Theme.Glyph.Refused, message!, detail!, null, wide: true);
                z.IsEnabled = false;
                zones.Children.Add(z);
            }
            foreach (var (o, i) in offers.Select((o, i) => (o, i)))
            {
                var z = Zone(o.Glyph, o.Action, o.Detail, o, wide: offers.Count == 1);
                z.Margin = new Thickness(i == 0 ? 0 : 6, 0, i == offers.Count - 1 ? 0 : 6, 0);
                zones.Children.Add(z);
            }
            body.Children.Add(zones);
            var foot = Theme.Text(dragging ? "drop on an action · move away to cancel" : "choose an action · Esc to cancel", 10.5, Theme.Secondary);
            foot.TextAlignment = TextAlignment.Center;
            foot.Margin = new Thickness(0, 10, 0, 0);
            body.Children.Add(foot);
        }
        Content = Theme.PanelBorder(body);
        TestHooks.Shot(this, "drop", staged == null ? "idle" : string.Join("|", Classify(staged).Offers.Select(o => o.Action)) + Classify(staged).Message);
    }

    Button Zone(Theme.Glyph glyph, string action, string detail, Offer? offer, bool wide)
    {
        var inner = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 14, 10, 14) };
        var tile = Theme.Tile(glyph);
        tile.HorizontalAlignment = HorizontalAlignment.Center;
        inner.Children.Add(tile);
        var a = Theme.Text(action, 13.5, Theme.Ink, FontWeights.SemiBold);
        a.TextAlignment = TextAlignment.Center;
        a.Margin = new Thickness(0, 8, 0, 2);
        inner.Children.Add(a);
        var d = Theme.Text(detail, 11, Theme.Secondary);
        d.TextAlignment = TextAlignment.Center;
        inner.Children.Add(d);
        var b = new Button { Style = Theme.Style("Zone"), Content = inner, MinHeight = wide ? 120 : 128, AllowDrop = offer != null };
        AutomationProperties.SetName(b, $"{action}. {detail}");
        if (offer != null)
        {
            b.Click += (_, _) => Go(offer);
            b.DragEnter += (_, e) => { b.Tag = "hot"; e.Effects = DragDropEffects.Copy; e.Handled = true; };
            b.DragOver += (_, e) => { e.Effects = DragDropEffects.Copy; e.Handled = true; };
            b.DragLeave += (_, _) => b.Tag = null;
            b.Drop += (_, e) => { e.Handled = true; Go(offer); };
        }
        return b;
    }

    void Go(Offer o)
    {
        Hide();
        dragging = false;
        staged = null;
        Render();
        run(o.Kind, o.Files);
    }

    void Choose()
    {
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Multiselect = true,
            Title = "Choose PDFs or photos",
            Filter = "PDFs and photos|*.pdf;*.jpg;*.jpeg;*.png;*.bmp;*.gif;*.tif;*.tiff|PDFs|*.pdf|Photos|*.jpg;*.jpeg;*.png;*.bmp;*.gif;*.tif;*.tiff",
        };
        if (dlg.ShowDialog(this) == true) ShowNear(dlg.FileNames);
    }
}
