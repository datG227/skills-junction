using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Browser = Microsoft.Web.WebView2.WinForms.WebView2;

namespace SkillsJunction.Desktop;

internal sealed class MainWindow : Form
{
    private const string Origin = "https://appassets.local/";
    private readonly Browser browser = new() { Dock = DockStyle.Fill };
    private BackendProcess? backend;
    private bool closing;

    public MainWindow()
    {
        Text = "Skills Junction";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(1080, 760);
        MinimumSize = new Size(780, 570);
        BackColor = Color.FromArgb(247, 247, 247);
        Controls.Add(browser);
        Shown += InitializeApplication;
        FormClosing += (_, _) =>
        {
            closing = true;
            backend?.Dispose();
            browser.Dispose();
        };
    }

    private async void InitializeApplication(object? sender, EventArgs args)
    {
        try
        {
            if (!File.Exists(Path.Combine(AppPaths.WebDirectory, "index.html")))
                throw new FileNotFoundException("Thiếu thư mục giao diện web.");
            var environment = await CoreWebView2Environment.CreateAsync(
                userDataFolder: Path.Combine(AppPaths.DataDirectory, "WebView2"));
            await browser.EnsureCoreWebView2Async(environment);
            if (closing) return;
            var core = browser.CoreWebView2;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            // Map only UI assets. Backend code/configuration must not be web content.
            // https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/working-with-local-content
            core.SetVirtualHostNameToFolderMapping("appassets.local", AppPaths.WebDirectory,
                CoreWebView2HostResourceAccessKind.DenyCors);
            core.NavigationStarting += (_, navigation) =>
                navigation.Cancel = !navigation.Uri.StartsWith(Origin, StringComparison.OrdinalIgnoreCase);
            core.NewWindowRequested += (_, window) => window.Handled = true;
            core.WebMessageReceived += ReceiveWebMessage;

            backend = new BackendProcess();
            backend.MessageReceived += json => PostMessage(json);
            backend.Stopped += () => PostMessage(JsonSerializer.Serialize(new
            {
                requestId = "backend-exited",
                ok = false,
                error = "Phần xử lý Junction đã dừng. Hãy đóng rồi mở lại ứng dụng.",
            }));
            backend.Start();
            core.Navigate(Origin + "index.html");
        }
        catch (Exception error)
        {
            if (closing) return;
            AppPaths.Log(error.ToString());
            MessageBox.Show(this,
                "Không thể mở ứng dụng. Kiểm tra các tệp đi kèm và Microsoft Edge WebView2 Runtime.\n\n" + error.Message,
                "Skills Junction", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Close();
        }
    }

    private async void ReceiveWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        if (closing || !args.Source.StartsWith(Origin, StringComparison.OrdinalIgnoreCase)) return;
        string requestId = "";
        try
        {
            using var document = JsonDocument.Parse(args.WebMessageAsJson);
            if (document.RootElement.TryGetProperty("requestId", out var id) && id.ValueKind == JsonValueKind.String)
                requestId = id.GetString() ?? "";
            if (backend is null) throw new InvalidOperationException("Phần xử lý Junction chưa sẵn sàng.");
            await backend.SendAsync(args.WebMessageAsJson);
        }
        catch (Exception error)
        {
            AppPaths.Log("Backend request: " + error);
            PostMessage(JsonSerializer.Serialize(new
            {
                requestId,
                ok = false,
                error = "Không kết nối được phần xử lý Junction: " + error.Message,
            }));
        }
    }

    private void PostMessage(string json)
    {
        if (closing || IsDisposed) return;
        try
        {
            BeginInvoke(() =>
            {
                if (!closing && browser.CoreWebView2 is not null)
                    browser.CoreWebView2.PostWebMessageAsJson(json);
            });
        }
        catch (InvalidOperationException) when (closing || IsDisposed) { }
    }
}
