using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace SkillsJunction.Desktop;

internal sealed class BackendProcess : IDisposable
{
    private readonly Process process;
    private readonly SemaphoreSlim writes = new(1, 1);
    private volatile bool stopping;
    private bool started;

    public event Action<string>? MessageReceived;
    public event Action? Stopped;

    public BackendProcess()
    {
        if (!File.Exists(AppPaths.BackendScript))
            throw new FileNotFoundException("Thiếu tệp xử lý Junction.", AppPaths.BackendScript);

        var powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        var start = new ProcessStartInfo(powershell)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
            WorkingDirectory = AppContext.BaseDirectory,
        };
        // Read the script explicitly as UTF-8, regardless of the console code page
        // or whether a contributor's editor writes a BOM.
        var script = AppPaths.BackendScript.Replace("'", "''");
        var bootstrap = "[Console]::InputEncoding=[Text.UTF8Encoding]::new($false); "
            + "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); "
            + $"& ([scriptblock]::Create([IO.File]::ReadAllText('{script}',[Text.Encoding]::UTF8))) -BackendServer";
        foreach (var argument in new[] { "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-EncodedCommand",
                     Convert.ToBase64String(Encoding.Unicode.GetBytes(bootstrap)) })
            start.ArgumentList.Add(argument);

        process = new Process { StartInfo = start, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, args) =>
        {
            if (stopping || string.IsNullOrWhiteSpace(args.Data)) return;
            try
            {
                using var document = JsonDocument.Parse(args.Data);
                MessageReceived?.Invoke(args.Data);
            }
            catch (JsonException error) { AppPaths.Log("Invalid backend response: " + error.Message); }
        };
        process.ErrorDataReceived += (_, args) =>
        {
            if (!string.IsNullOrWhiteSpace(args.Data)) AppPaths.Log("PowerShell: " + args.Data);
        };
        process.Exited += (_, _) =>
        {
            if (!stopping)
            {
                AppPaths.Log("Backend exited. ExitCode=" + process.ExitCode);
                Stopped?.Invoke();
            }
        };
    }

    public void Start()
    {
        if (!process.Start()) throw new InvalidOperationException("Không mở được phần xử lý Junction.");
        started = true;
        process.StandardInput.AutoFlush = true;
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }

    public async Task SendAsync(string json)
    {
        await writes.WaitAsync();
        try
        {
            if (stopping || !started || process.HasExited)
                throw new InvalidOperationException("Phần xử lý Junction đã dừng.");
            await process.StandardInput.WriteLineAsync(json);
        }
        finally { writes.Release(); }
    }

    public void Dispose()
    {
        if (stopping) return;
        stopping = true;
        try
        {
            if (started && !process.HasExited)
            {
                process.StandardInput.WriteLine("{\"requestId\":\"host-close\",\"action\":\"quit\"}");
                process.StandardInput.Close();
                if (!process.WaitForExit(1500)) process.Kill(entireProcessTree: true);
                process.WaitForExit();
            }
        }
        catch (IOException error) { AppPaths.Log("Backend close: " + error.Message); }
        catch (InvalidOperationException error) { AppPaths.Log("Backend close: " + error.Message); }
        finally
        {
            // A broken stdin must not leave our hidden PowerShell process running.
            if (started && !process.HasExited) process.Kill(entireProcessTree: true);
            process.Dispose();
        }
    }
}
