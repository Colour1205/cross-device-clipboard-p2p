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
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
