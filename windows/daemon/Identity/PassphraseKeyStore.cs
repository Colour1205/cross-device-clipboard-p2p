using ClipboardDaemon.Crypto;

namespace ClipboardDaemon.Identity;

// Persists the key derived from the user's passcode (never the passcode
// itself) so it only needs to be entered once — same load-or-create-on-disk
// shape as DeviceIdentity's keypair.
public class PassphraseKeyStore
{
    private byte[]? key;
    private readonly string key_path;

    public PassphraseKeyStore(string label)
    {
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        key_path = Path.Combine(app_data_dir, "ClipboardDaemon", $"passphrasekey{label}.key");
        Directory.CreateDirectory(Path.Combine(app_data_dir, "ClipboardDaemon"));

        if (File.Exists(key_path))
        {
            key = File.ReadAllBytes(key_path);
        }
    }

    public bool HasPassphrase => key != null;

    public byte[]? GetKey() => key;

    // Deliberately fixed, not random: every device deriving from the same
    // passphrase must land on the same key, or none of them could ever verify
    // each other's proofs. A shared-secret KDF salt doesn't need to be unique
    // per device the way a login-password salt would — it only needs to be
    // the same everywhere this app derives a key from a passphrase.
    private static readonly byte[] FixedSalt = System.Text.Encoding.UTF8.GetBytes("ClipboardDaemonPassphraseSaltV1");

    public void SetPassphrase(string passphrase)
    {
        key = PassphraseAuth.DeriveKey(passphrase, FixedSalt);
        File.WriteAllBytes(key_path, key);
    }
}
