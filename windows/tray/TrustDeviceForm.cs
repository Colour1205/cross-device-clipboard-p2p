namespace ClipboardTray;

// Manual fallback for pairing: paste another device's public key (shown via
// its own "Show My QR Code" dialog) to trust it, without needing a camera/
// QR-scanning UI, which doesn't exist on Windows yet.
public class TrustDeviceForm : Form
{
    private readonly TextBox keyInput;

    public string EnteredKey => keyInput.Text.Trim();

    public TrustDeviceForm()
    {
        Text = "Trust a Device";
        Width = 420;
        Height = 220;
        StartPosition = FormStartPosition.CenterScreen;

        var label = new Label
        {
            Text = "Paste the other device's public key:",
            Dock = DockStyle.Top,
            Height = 30
        };

        keyInput = new TextBox
        {
            Multiline = true,
            Dock = DockStyle.Top,
            Height = 100
        };

        var okButton = new Button
        {
            Text = "Trust",
            DialogResult = DialogResult.OK,
            Dock = DockStyle.Bottom
        };

        var cancelButton = new Button
        {
            Text = "Cancel",
            DialogResult = DialogResult.Cancel,
            Dock = DockStyle.Bottom
        };

        Controls.Add(okButton);
        Controls.Add(cancelButton);
        Controls.Add(keyInput);
        Controls.Add(label);

        AcceptButton = okButton;
        CancelButton = cancelButton;
    }
}
