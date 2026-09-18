using System.Diagnostics;

namespace ClipboardTray;

// Best-effort auto-start of the daemon if it's not already reachable via IPC.
// Locates the sibling ClipboardDaemon.exe assuming the conventional dev-time
// project layout (windows/tray/ next to windows/daemon/). A real installed
// deployment would ship both at a fixed, known path instead — future work.
public static class DaemonLauncher
{
    public static bool TryStart(string label)
    {
        string trayDir = AppContext.BaseDirectory.TrimEnd('\\', '/');
        string daemonDir = trayDir.Replace("\\tray\\", "\\daemon\\");
        string daemonExe = Path.Combine(daemonDir, "ClipboardDaemon.exe");

        if (!File.Exists(daemonExe))
        {
            return false;
        }

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = daemonExe,
                Arguments = label,
                UseShellExecute = false,
                // Was true - which meant every Console.WriteLine debug line
                // this daemon prints (connection/disconnect, file transfer
                // progress, discovered peers, etc.) went nowhere visible in
                // the normal auto-started flow. A visible console window is
                // the actual point of those log lines.
                CreateNoWindow = false
            });
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
