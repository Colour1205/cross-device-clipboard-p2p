namespace ClipboardDaemon.Identity;

// Address is the peer's last-known reachable address off-LAN (e.g. a
// Tailscale IP), learned at pairing time and used as a fallback when LAN
// broadcast discovery can't find this device directly.
public record TrustedDevice(string PublicKey, string? Address = null);

public class TrustStore
{
    private Dictionary<string, TrustedDevice> trustedDevices = new Dictionary<string, TrustedDevice>();
    private string truststore_path;

    public TrustStore(string? label = "")
    {
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        truststore_path = Path.Combine(app_data_dir, "ClipboardDaemon", $"truststore{label}.json");
        Directory.CreateDirectory(Path.Combine(app_data_dir, "ClipboardDaemon"));
        if (File.Exists(truststore_path))
        {
            string json = File.ReadAllText(truststore_path);
            var devices = System.Text.Json.JsonSerializer.Deserialize<List<TrustedDevice>>(json) ?? new List<TrustedDevice>();
            foreach (var device in devices)
            {
                trustedDevices[device.PublicKey] = device;
            }
        }
    }

    public bool IsTrusted(string key)
    {
        return trustedDevices.ContainsKey(key);
    }

    public void Trust(string publicKey, string? address = null)
    {
        trustedDevices[publicKey] = new TrustedDevice(publicKey, address);
        saveTrustStore();
    }

    public void Untrust(string key)
    {
        trustedDevices.Remove(key);
        saveTrustStore();
    }

    // Trusted devices we have a cached off-LAN address for — used by the
    // reconnect loop to reach peers that LAN broadcast discovery can't find.
    public IEnumerable<TrustedDevice> GetTrustedDevicesWithAddress()
    {
        return trustedDevices.Values.Where(d => !string.IsNullOrWhiteSpace(d.Address));
    }

    public void saveTrustStore()
    {
        string json = System.Text.Json.JsonSerializer.Serialize(trustedDevices.Values.ToList());
        File.WriteAllText(truststore_path, json);
    }
}
