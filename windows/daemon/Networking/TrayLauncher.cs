using System.Diagnostics;

namespace ClipboardDaemon.Networking;

// Best-effort auto-start of the tray app if it's not already running. Mirrors
// DaemonLauncher on the tray side — same dev-time sibling-folder assumption.
public static class TrayLauncher
{
    public static bool TryStart(string label)
    {
        if (Process.GetProcessesByName("ClipboardTray").Length > 0)
        {
            return true; // already running
        }

        string daemonDir = AppContext.BaseDirectory.TrimEnd('\\', '/');
        string trayDir = daemonDir.Replace("\\daemon\\", "\\tray\\");
        string trayExe = Path.Combine(trayDir, "ClipboardTray.exe");

        if (!File.Exists(trayExe))
        {
            Console.WriteLine($"Could not auto-start tray: no exe at expected path '{trayExe}' (build the tray project first, or it's laid out differently than the dev-time sibling-folder assumption).");
            return false;
        }

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = trayExe,
                Arguments = label,
                UseShellExecute = false
            });
            Console.WriteLine($"Auto-started tray app: {trayExe}");
            return true;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Could not auto-start tray: {ex.Message}");
            return false;
        }
    }
}
