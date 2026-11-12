// One Jack per user session. Explorer starts one Jack.exe per selected file (classic verbs pass
// "%1"); every process that is not the first forwards its request over a named pipe to the first
// and exits, and the first gathers requests arriving close together into one card.
//
// Security: the pipe and mutex names carry the session id and the user's SID, and both ends use
// PipeOptions.CurrentUserOnly (the server's ACL admits only this user; the client checks the
// server is owned by this user). Requests are validated before use: known verbs only, absolute
// paths that exist, the right extensions, at most MaxFiles files.
using System.Diagnostics;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace Jack.App;

internal sealed record Request(string Verb, string[] Files);

internal static class Instance
{
    public const int MaxFiles = 500;
    public static readonly string[] Verbs = { "word", "searchable", "photos", "drop", "show", "quit" };

    static string Id
    {
        get
        {
            var sid = WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
            return $"Jack.App.{Process.GetCurrentProcess().SessionId}.{sid}";
        }
    }

    /// The mutex while this process is the first Jack in the session, else null.
    public static Mutex? TryBecomePrimary()
    {
        var m = new Mutex(true, @"Local\" + Id, out bool created);
        if (created) return m;
        m.Dispose();
        return null;
    }

    /// Hands a request to the running Jack. The first Jack may still be starting its pipe, so
    /// this retries until `timeout`.
    public static bool Forward(Request r, TimeSpan timeout)
    {
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(r));
        var until = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < until)
        {
            try
            {
                using var c = new NamedPipeClientStream(".", Id, PipeDirection.Out, PipeOptions.CurrentUserOnly);
                c.Connect(500);
                c.Write(bytes, 0, bytes.Length);
                c.Flush();
                return true;
            }
            catch (TimeoutException) { }
            catch (IOException) { Thread.Sleep(100); }
        }
        return false;
    }

    /// Listens on a background thread; `onRequest` gets every valid request.
    public static void Serve(Action<Request> onRequest, CancellationToken stop)
    {
        var t = new Thread(() =>
        {
            while (!stop.IsCancellationRequested)
            {
                try
                {
                    using var s = new NamedPipeServerStream(Id, PipeDirection.In, NamedPipeServerStream.MaxAllowedServerInstances,
                        PipeTransmissionMode.Byte, PipeOptions.CurrentUserOnly | PipeOptions.Asynchronous);
                    s.WaitForConnectionAsync(stop).GetAwaiter().GetResult();
                    using var ms = new MemoryStream();
                    var buf = new byte[8192];
                    int n;
                    while ((n = s.Read(buf, 0, buf.Length)) > 0)
                    {
                        ms.Write(buf, 0, n);
                        if (ms.Length > 1 << 20) throw new InvalidDataException("request too large");
                    }
                    var r = JsonSerializer.Deserialize<Request>(ms.ToArray());
                    if (r != null && Validate(r) is Request ok) onRequest(ok);
                }
                catch (OperationCanceledException) { return; }
                catch (Exception e) { Log.Write("pipe: " + e.Message); }
            }
        }) { IsBackground = true, Name = "Jack pipe" };
        t.Start();
    }

    /// Known verb, absolute existing files with the right extension, at most MaxFiles. Files
    /// that don't fit are dropped; a request left with nothing to do is dropped.
    public static Request? Validate(Request r)
    {
        if (!Verbs.Contains(r.Verb)) return null;
        var files = (r.Files ?? Array.Empty<string>()).Take(MaxFiles)
            .Where(f => !string.IsNullOrWhiteSpace(f) && Path.IsPathFullyQualified(f) && File.Exists(f))
            .Where(f => r.Verb switch
            {
                "word" or "searchable" => Path.GetExtension(f).Equals(".pdf", StringComparison.OrdinalIgnoreCase),
                "photos" => PhotosToPdf.IsPhoto(f),
                _ => true,
            })
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (r.Verb is "word" or "searchable" or "photos" && files.Length == 0) return null;
        return r with { Files = files };
    }
}

/// %LOCALAPPDATA%\Jack\jack.log, small and best effort (never file contents, only names and states).
internal static class Log
{
    static readonly object gate = new();
    public static string PathName => System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jack", "jack.log");
    public static void Write(string line)
    {
        try
        {
            lock (gate)
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(PathName)!);
                var fi = new FileInfo(PathName);
                if (fi.Exists && fi.Length > 1 << 20) File.Move(PathName, PathName + ".1", overwrite: true);
                File.AppendAllText(PathName, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {line}{Environment.NewLine}");
            }
        }
        catch { }
    }
}
