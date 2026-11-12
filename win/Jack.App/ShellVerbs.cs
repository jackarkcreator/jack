// Explorer right-click verbs, per user (HKCU). The MSI (step 5) writes the same keys per machine.
// On Windows 11 these classic verbs sit under "Show more options"; a top-level entry needs a
// sparse package (step 4b).
//   PDF:    "Convert to Word with Jack"     Jack.exe --to-word "%1"
//           "Make searchable with Jack"     Jack.exe --searchable "%1"
//   Photos: "Combine into one PDF with Jack" Jack.exe --photos "%1"
// Default MultiSelectModel ("Document"): Explorer starts one Jack.exe per selected file and the
// first one gathers them (Instance). Windows shows these verbs for up to 15 selected files; more
// needs the Windows 11 command handler (step 4b), which gets the whole selection at once.
using Microsoft.Win32;

namespace Jack.App;

internal static class ShellVerbs
{
    const string Root = @"Software\Classes\SystemFileAssociations";
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    static readonly (string Assoc, string Key, string Label, string Arg)[] All =
    {
        (".pdf", "Jack.ToWord", "Convert to Word with Jack", "--to-word"),
        (".pdf", "Jack.Searchable", "Make searchable with Jack", "--searchable"),
        ("image", "Jack.Photos", "Combine into one PDF with Jack", "--photos"),
    };

    public static void Register(string exe)
    {
        foreach (var v in All)
        {
            using var k = Registry.CurrentUser.CreateSubKey($@"{Root}\{v.Assoc}\shell\{v.Key}");
            k.SetValue("", v.Label);
            k.SetValue("MUIVerb", v.Label);
            k.SetValue("Icon", $"\"{exe}\",0");
            using var c = k.CreateSubKey("command");
            c.SetValue("", $"\"{exe}\" {v.Arg} \"%1\"");
        }
    }

    /// Start Jack in the tray at sign-in (`exe`), or not (null).
    public static void SetAutostart(string? exe)
    {
        using var r = Registry.CurrentUser.CreateSubKey(RunKey);
        if (exe != null) r.SetValue("Jack", $"\"{exe}\" --tray");
        else r.DeleteValue("Jack", throwOnMissingValue: false);
    }

    public static void Unregister()
    {
        UnregisterVerbs();
        SetAutostart(null);
    }

    public static void UnregisterVerbs()
    {
        foreach (var v in All)
            Registry.CurrentUser.DeleteSubKeyTree($@"{Root}\{v.Assoc}\shell\{v.Key}", throwOnMissingSubKey: false);
    }

    /// What is registered now (for --status and the CI check).
    public static IEnumerable<string> Describe()
    {
        foreach (var v in All)
        {
            using var c = Registry.CurrentUser.OpenSubKey($@"{Root}\{v.Assoc}\shell\{v.Key}\command");
            yield return $"{v.Assoc} {v.Key}: {(c?.GetValue("") as string) ?? "(not registered)"}";
        }
        using var r = Registry.CurrentUser.OpenSubKey(RunKey);
        yield return $"autostart: {(r?.GetValue("Jack") as string) ?? "(off)"}";
    }
}
