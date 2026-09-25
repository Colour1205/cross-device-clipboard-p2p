namespace ClipboardTray;

class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        string label = args.Length > 0 ? args[0] : "default";
        var ipcClient = new IpcClient(label);

        // auto-start the daemon if it's not already running — the normal case
        // going forward is "double-click the tray app," not "manually run two
        // separate processes." Give it a moment to boot before retrying.
        var pingResponse = ipcClient.Send(new IpcRequest("get_public_key")).GetAwaiter().GetResult();
        if (pingResponse == null && DaemonLauncher.TryStart(label))
        {
            System.Threading.Thread.Sleep(2000);
        }

        // first-run: offer passcode-based auto-pairing setup. Blocking here (before
        // Application.Run starts the message loop) is fine — same as a console app
        // doing setup work before its main loop; there's no pump to deadlock against yet.
        var hasPassphraseResponse = ipcClient.Send(new IpcRequest("has_passphrase")).GetAwaiter().GetResult();
        if (hasPassphraseResponse != null && hasPassphraseResponse.Success && hasPassphraseResponse.Data == "False")
        {
            using var passcodeForm = new PasscodeForm();
            if (passcodeForm.ShowDialog() == DialogResult.OK && !string.IsNullOrWhiteSpace(passcodeForm.EnteredPasscode))
            {
                ipcClient.Send(new IpcRequest("set_passphrase", passcodeForm.EnteredPasscode)).GetAwaiter().GetResult();
            }
        }

        var menu = new ContextMenuStrip();

        var pairingItem = new ToolStripMenuItem("Pairing...");
        pairingItem.Click += (s, e) =>
        {
            new PairingForm(ipcClient).Show();
        };

        var manageItem = new ToolStripMenuItem("Manage Devices");
        manageItem.Click += (s, e) =>
        {
            new ManageDevicesForm(ipcClient).ShowDialog();
        };

        var exitItem = new ToolStripMenuItem("Exit");
        exitItem.Click += (s, e) => Application.Exit();

        menu.Items.Add(pairingItem);
        menu.Items.Add(manageItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(exitItem);

        using var trayIcon = new NotifyIcon
        {
            Icon = AppIcon.Tray,
            Visible = true,
            Text = "Clipboard P2P",
            ContextMenuStrip = menu
        };

        Application.Run();
    }
}
