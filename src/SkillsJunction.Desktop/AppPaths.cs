namespace SkillsJunction.Desktop;

internal static class AppPaths
{
    public static string WebDirectory => Path.Combine(AppContext.BaseDirectory, "web");
    public static string BackendScript => Path.Combine(AppContext.BaseDirectory, "backend", "SkillsJunction.WebView2.ps1");

    // The backend uses LOCALAPPDATA too; keep profiles/configuration in agreement.
    public static string DataDirectory => Path.Combine(
        Environment.GetEnvironmentVariable("LOCALAPPDATA")
            ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SkillsJunction");

    public static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(DataDirectory);
            File.AppendAllText(Path.Combine(DataDirectory, "WebView2.log"),
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
