namespace ClipboardDaemon.Identity;

public class TrustStore
{
    private HashSet<string> trustedKeys = new HashSet<string>();
    private string app_data_dir;
    private string truststore_path;
    public TrustStore(string? label = "")
    {
        app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        truststore_path = Path.Combine(app_data_dir, "ClipboardDaemon", $"truststore{label}.json");
        Directory.CreateDirectory(Path.Combine(app_data_dir, "ClipboardDaemon"));
        if (File.Exists(truststore_path))
        {
            string json = File.ReadAllText(truststore_path);
            trustedKeys = System.Text.Json.JsonSerializer.Deserialize<HashSet<string>>(json) ?? new HashSet<string>();
        }
        else
        {
            trustedKeys = new HashSet<string>();
        }
    }
    public bool IsTrusted(string key)
    {
        return trustedKeys.Contains(key);
    }
    public void Trust(string key)
    {
        trustedKeys.Add(key);
        saveTrustStore();
    }
    public void Untrust(string key)
    {
        trustedKeys.Remove(key);
        saveTrustStore();
    }
    public void saveTrustStore()
    {
        string json = System.Text.Json.JsonSerializer.Serialize(trustedKeys);
        File.WriteAllText(truststore_path, json);
    }
}