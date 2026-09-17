using QRCoder;

namespace ClipboardTray;

// Shows this device's pairing info (public key + optional Tailscale address)
// as a QR code (for a future mobile app to scan) plus the raw JSON underneath
// (for pasting into another Windows device's "Trust a Device" dialog today,
// before any scanning UI exists).
public class QrCodeForm : Form
{
    public QrCodeForm(PairingInfo pairingInfo)
    {
        Text = "Pair This Device";
        Width = 420;
        Height = 560;
        StartPosition = FormStartPosition.CenterScreen;

        string payload = System.Text.Json.JsonSerializer.Serialize(pairingInfo);

        using var qrGenerator = new QRCodeGenerator();
        using var qrCodeData = qrGenerator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.Q);
        using var qrCode = new QRCode(qrCodeData);
        var qrImage = qrCode.GetGraphic(8);

        var pictureBox = new PictureBox
        {
            Image = qrImage,
            SizeMode = PictureBoxSizeMode.Zoom,
            Dock = DockStyle.Top,
            Height = 380
        };

        var addressLabel = new Label
        {
            Text = pairingInfo.Address != null
                ? $"Tailscale address included: {pairingInfo.Address}"
                : "No Tailscale address detected — LAN pairing only.",
            Dock = DockStyle.Top,
            Height = 24,
            TextAlign = System.Drawing.ContentAlignment.MiddleCenter
        };

        var textBox = new TextBox
        {
            Text = payload,
            ReadOnly = true,
            Dock = DockStyle.Bottom,
            Height = 60,
            Multiline = true,
            ScrollBars = ScrollBars.Vertical
        };

        Controls.Add(textBox);
        Controls.Add(addressLabel);
        Controls.Add(pictureBox);
    }
}
