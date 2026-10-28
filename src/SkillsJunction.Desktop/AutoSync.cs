using System.Text.Json;

namespace SkillsJunction.Desktop;

// Watches the source folder of every enabled pair and asks the backend to
// reconcile when a skill directory appears or disappears.
internal sealed class AutoSync : IDisposable
{
    private readonly BackendProcess backend;
    private readonly Dictionary<string, PairWatcher> watchers = new(StringComparer.Ordinal);
    private bool disposed;

    public AutoSync(BackendProcess backend)
    {
        this.backend = backend;
    }

    public void Update(string responseJson)
    {
        if (disposed) return;
        try
        {
            using var document = JsonDocument.Parse(responseJson);
            if (!document.RootElement.TryGetProperty("pairs", out var pairs) || pairs.ValueKind != JsonValueKind.Array)
                return;
            var active = new HashSet<string>(StringComparer.Ordinal);
            foreach (var pair in pairs.EnumerateArray())
            {
                if (pair.ValueKind != JsonValueKind.Object) continue;
                if (!pair.TryGetProperty("id", out var idElement) || idElement.ValueKind != JsonValueKind.String) continue;
                if (!pair.TryGetProperty("source", out var sourceElement) || sourceElement.ValueKind != JsonValueKind.String) continue;
                var id = idElement.GetString() ?? "";
                var source = sourceElement.GetString() ?? "";
                var on = pair.TryGetProperty("on", out var onElement) && onElement.ValueKind == JsonValueKind.True;
                var sourceMissing = pair.TryGetProperty("health", out var health) &&
                    health.ValueKind == JsonValueKind.Object &&
                    health.TryGetProperty("sourceMissing", out var missing) &&
                    missing.ValueKind == JsonValueKind.True;
                if (!on || sourceMissing || !Directory.Exists(source)) continue;
                active.Add(id);
                if (watchers.TryGetValue(id, out var existing) && SamePath(existing.Source, source)) continue;
                existing?.Dispose();
                try
                {
                    watchers[id] = new PairWatcher(id, source, RequestSync);
                }
                catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException)
                {
                    AppPaths.Log("Auto-sync watcher: " + error.Message);
                    watchers.Remove(id);
                }
            }
            foreach (var id in watchers.Keys.Where(id => !active.Contains(id)).ToList())
            {
                watchers[id].Dispose();
                watchers.Remove(id);
            }
        }
        catch (JsonException error)
        {
            AppPaths.Log("Auto-sync response: " + error.Message);
        }
    }

    private void RequestSync(string pairId)
    {
        if (disposed) return;
        var request = JsonSerializer.Serialize(new
        {
            requestId = "auto-" + Guid.NewGuid().ToString("N"),
            action = "sync",
            id = pairId,
            silent = true,
        });
        _ = SendAsync(request);
    }

    private async Task SendAsync(string request)
    {
        try { await backend.SendAsync(request); }
        catch (Exception error) { AppPaths.Log("Auto-sync request: " + error.Message); }
    }

    private static bool SamePath(string first, string second)
    {
        try
        {
            return string.Equals(
                Path.TrimEndingDirectorySeparator(Path.GetFullPath(first)),
                Path.TrimEndingDirectorySeparator(Path.GetFullPath(second)),
                StringComparison.OrdinalIgnoreCase);
        }
        catch (ArgumentException) { return false; }
    }

    public void Dispose()
    {
        disposed = true;
        foreach (var watcher in watchers.Values) watcher.Dispose();
        watchers.Clear();
    }

    private sealed class PairWatcher : IDisposable
    {
        private readonly FileSystemWatcher watcher;
        private readonly System.Threading.Timer debounce;

        public string Source { get; }

        public PairWatcher(string id, string source, Action<string> sync)
        {
            Source = source;
            debounce = new System.Threading.Timer(_ => sync(id), null, Timeout.Infinite, Timeout.Infinite);
            watcher = new FileSystemWatcher(source)
            {
                IncludeSubdirectories = false,
                NotifyFilter = NotifyFilters.DirectoryName,
            };
            watcher.Created += OnChanged;
            watcher.Deleted += OnChanged;
            watcher.Renamed += OnRenamed;
            watcher.Error += OnError;
            watcher.EnableRaisingEvents = true;
            // Catch up on skills added while the app was not running.
            Schedule();
        }

        private void OnChanged(object sender, FileSystemEventArgs args) => Schedule();
        private void OnRenamed(object sender, RenamedEventArgs args) => Schedule();
        private void OnError(object sender, ErrorEventArgs args) => Schedule();
        private void Schedule() => debounce.Change(500, Timeout.Infinite);

        public void Dispose()
        {
            watcher.EnableRaisingEvents = false;
            watcher.Dispose();
            debounce.Dispose();
        }
    }
}
