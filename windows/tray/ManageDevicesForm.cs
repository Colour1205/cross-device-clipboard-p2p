using System.Text.Json;

namespace ClipboardTray;

// Lists every trusted device, marks which ones are currently connected, and
// lets you untrust one — the missing "revoke" side of pairing.
public class ManageDevicesForm : Form
{
    private readonly IpcClient ipcClient;
    private readonly ListView listView;

    public ManageDevicesForm(IpcClient ipcClient)
    {
        this.ipcClient = ipcClient;
        Text = "Manage Devices";
        Width = 480;
        Height = 400;
        StartPosition = FormStartPosition.CenterScreen;

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
        Controls.Add(untrustButton);

        Load += async (s, e) => await RefreshDevices();
    }

    private async Task RefreshDevices()
    {
        listView.Items.Clear();

        var trustedResponse = await ipcClient.Send(new IpcRequest("list_trusted"));
        var connectedResponse = await ipcClient.Send(new IpcRequest("list_connections"));

        if (trustedResponse == null || !trustedResponse.Success)
        {
            MessageBox.Show("Could not reach the daemon. Is it running?", "Error");
            return;
        }

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
