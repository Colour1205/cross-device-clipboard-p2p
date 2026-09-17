namespace ClipboardTray;

// Shown once, on first run (no passphrase configured yet). Entering the same
// passcode on multiple devices lets them auto-trust each other with no QR/key
// exchange — purely optional, cancelling just means using manual pairing only.
public class PasscodeForm : Form
{
    private readonly TextBox passcodeInput;

    public string EnteredPasscode => passcodeInput.Text;

    public PasscodeForm()
    {
        Text = "Set Up Device Pairing";
        Width = 440;
        Height = 220;
        StartPosition = FormStartPosition.CenterScreen;

        var label = new Label
        {
            Text = "Enter a passcode. Any of your other devices using the same\n" +
                   "passcode will automatically trust this one — no need to scan\n" +
                   "a QR code. You can skip this and pair devices manually instead.",
            Dock = DockStyle.Top,
            Height = 70
        };

        passcodeInput = new TextBox
        {
            Dock = DockStyle.Top,
            Height = 30,
            UseSystemPasswordChar = true
        };

        var okButton = new Button
        {
            Text = "Set Passcode",
            DialogResult = DialogResult.OK,
            Dock = DockStyle.Bottom
        };

        var skipButton = new Button
        {
            Text = "Skip",
            DialogResult = DialogResult.Cancel,
            Dock = DockStyle.Bottom
        };

        Controls.Add(okButton);
        Controls.Add(skipButton);
        Controls.Add(passcodeInput);
        Controls.Add(label);

        AcceptButton = okButton;
        CancelButton = skipButton;
    }
}
