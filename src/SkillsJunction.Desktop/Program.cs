namespace SkillsJunction.Desktop;

internal static class Program
{
    private const string InstanceMutexName = @"Local\SkillsJunction.WebView2.SingleInstance";

    [STAThread]
    private static void Main()
    {
        using var instanceMutex = new Mutex(true, InstanceMutexName, out var createdNew);
        if (!createdNew)
        {
            MessageBox.Show("Skills Junction đang chạy. Hãy dùng cửa sổ đang mở.", "Skills Junction",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        try
        {
            Application.SetHighDpiMode(HighDpiMode.SystemAware);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainWindow());
        }
        finally
        {
            instanceMutex.ReleaseMutex();
        }
    }
}
