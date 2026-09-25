namespace ClipboardDaemon.Identity;

// Address is the peer's last-known reachable address off-LAN (e.g. a
// Tailscale IP), learned at pairing time and used as a fallback when LAN
// broadcast discovery can't find this device directly.
public record TrustedDevice(string PublicKey, string? Address = null);

public class TrustStore
{
    private Dictionary<string, TrustedDevice> trustedDevices = new Dictionary<string, TrustedDevice>();
    private string truststore_path;
    // Every connection path (TCP accept, beacon handler, off-LAN reconnect
    // loop, IPC) reads and writes this from its own thread. Unlocked, two
    // writes at once collided on the file ("being used by another process"),
    // and a write during the reconnect loop's enumeration threw
    // "collection was modified" - each killing whatever loop it hit.
    private readonly object gate = new();

    public TrustStore(string? label = "")
    {
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        truststore_path = Path.Combine(app_data_dir, "ClipboardDaemon", $"truststore{label}.json");
        Directory.CreateDirectory(Path.Combine(app_data_dir, "ClipboardDaemon"));
        if (File.Exists(truststore_path))
        {
            try
            {
                string json = File.ReadAllText(truststore_path);
                var devices = System.Text.Json.JsonSerializer.Deserialize<List<TrustedDevice>>(json) ?? new List<TrustedDevice>();
                foreach (var device in devices)
                {
                    trustedDevices[device.PublicKey] = device;
                }
            }
            catch (System.Text.Json.JsonException ex)
            {
                // regenerate rather than crash — this does mean any existing pairings
                // are lost and would need to be redone, but that's better than the
                // daemon refusing to start at all
                Console.WriteLine($"Could not load trust store ({ex.Message}) — starting with no trusted devices.");
            }
        }
    }

    public bool IsTrusted(string key)
    {
        lock (gate) { return trustedDevices.ContainsKey(key); }
    }

    public void Trust(string publicKey, string? address = null)
    {
        lock (gate)
        {
            trustedDevices[publicKey] = new TrustedDevice(publicKey, address);
            saveTrustStore();
        }
    }

    public void Untrust(string key)
    {
        lock (gate)
        {
            trustedDevices.Remove(key);
            saveTrustStore();
        }
    }

    // Trusted devices we have a cached off-LAN address for — used by the
    // reconnect loop to reach peers that LAN broadcast discovery can't find.
    // A snapshot, so callers can enumerate it while other threads write.
    public IEnumerable<TrustedDevice> GetTrustedDevicesWithAddress()
    {
        lock (gate) { return trustedDevices.Values.Where(d => !string.IsNullOrWhiteSpace(d.Address)).ToList(); }
    }

    // Every trusted device, address or not — for a "manage devices" UI.
    public IEnumerable<TrustedDevice> GetAllTrustedDevices()
    {
        lock (gate) { return trustedDevices.Values.ToList(); }
    }

    public void saveTrustStore()
    {
        lock (gate)
        {
            string json = System.Text.Json.JsonSerializer.Serialize(trustedDevices.Values.ToList());
            File.WriteAllText(truststore_path, json);
        }
    }
}
