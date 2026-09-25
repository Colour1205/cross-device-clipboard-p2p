using System.Text.Json;

namespace ClipboardTray;

// Lists every trusted device, marks which ones are currently connected, and
// lets you untrust one — the missing "revoke" side of pairing.
public class ManageDevicesForm : Form
{
    private readonly IpcClient ipcClient;
    private readonly ListView listView;
    private readonly Label statusLabel;
    private readonly System.Windows.Forms.Timer pollTimer;
    // Guards against overlapping polls - without it, a Tick firing while a
    // previous RefreshDevices() is still awaiting (e.g. the daemon isn't
    // responding) stacks up more and more concurrent calls, each shown to
    // the user - that's what caused a cascade of "Could not reach the
    // daemon" dialogs when the daemon was stopped.
    private bool isRefreshing = false;

    public ManageDevicesForm(IpcClient ipcClient)
    {
        this.ipcClient = ipcClient;
        Text = "Manage Devices";
        Icon = AppIcon.Window;
        Width = 480;
        Height = 400;
        StartPosition = FormStartPosition.CenterScreen;

        statusLabel = new Label
        {
            Text = "",
            Dock = DockStyle.Top,
            Height = 24,
            ForeColor = System.Drawing.Color.Firebrick,
            Visible = false
        };

        listView = new ListView
        {
            Dock = DockStyle.Fill,
            View = View.Details,
            FullRowSelect = true
        };
        listView.Columns.Add("Device", 320);
        listView.Columns.Add("Status", 110);

        var untrustButton = new Button
        {
            Text = "Untrust Selected",
            Dock = DockStyle.Bottom,
            Height = 32
        };
        untrustButton.Click += async (s, e) =>
        {
            if (listView.SelectedItems.Count == 0) return;
            string key = (string)listView.SelectedItems[0].Tag!;
            await ipcClient.Send(new IpcRequest("untrust_device", key));
            await RefreshDevices();
        };

        Controls.Add(listView);
        Controls.Add(statusLabel);
        Controls.Add(untrustButton);

        // Previously only refreshed once on Load - the Connected/Not
        // connected column never moved again after that, no matter what
        // actually happened, since nothing re-queried the daemon. Polling
        // while this window is open is the same low-effort fix
        // PairingForm's pending-request check already uses.
        pollTimer = new System.Windows.Forms.Timer { Interval = 1500 };
        pollTimer.Tick += async (s, e) => await RefreshDevices();
        FormClosed += (s, e) => pollTimer.Stop();

        Load += async (s, e) => { await RefreshDevices(); pollTimer.Start(); };
    }

    // Rebuilding the whole list every poll (rather than diffing in place)
    // does lose the current selection - acceptable here since this list is
    // short and mostly glanced at, not actively navigated with the keyboard
    // between polls.
    private async Task RefreshDevices()
    {
        if (isRefreshing) return; // previous poll still in flight - don't pile another on top
        isRefreshing = true;
        try
        {
            await RefreshDevicesCore();
        }
        finally
        {
            isRefreshing = false;
        }
    }

    private async Task RefreshDevicesCore()
    {
        var trustedResponse = await ipcClient.Send(new IpcRequest("list_trusted"));
        var connectedResponse = await ipcClient.Send(new IpcRequest("list_connections"));

        if (trustedResponse == null || !trustedResponse.Success)
        {
            // Inline status text, not a MessageBox - this runs on every poll
            // tick while the daemon is unreachable, and a modal dialog per
            // tick is exactly what caused the earlier cascade. The list
            // itself is left as-is (not cleared) so a transient hiccup
            // doesn't blank it out.
            statusLabel.Text = "Could not reach the daemon - is it running?";
            statusLabel.Visible = true;
            return;
        }
        statusLabel.Visible = false;

        listView.Items.Clear();
        var trusted = trustedResponse.Data != null
            ? JsonSerializer.Deserialize<List<TrustedDevice>>(trustedResponse.Data) ?? new()
            : new List<TrustedDevice>();
        var connected = connectedResponse?.Data != null
            ? JsonSerializer.Deserialize<List<string>>(connectedResponse.Data) ?? new()
            : new List<string>();

        foreach (var device in trusted)
        {
            string shortKey = device.PublicKey.Length > 28 ? device.PublicKey[..28] + "..." : device.PublicKey;
            var item = new ListViewItem(shortKey);
            item.SubItems.Add(connected.Contains(device.PublicKey) ? "Connected" : "Not connected");
            item.Tag = device.PublicKey;
            listView.Items.Add(item);
        }
    }
}
