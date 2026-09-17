namespace ClipboardDaemon.Storage;

// Content-addressed local storage for synced files — keyed by the SHA256 hash
// of the file's bytes (hex string), so identical content is never stored
// twice, and evicting a history entry can reliably find (and delete) the
// exact blob it refers to, without any other bookkeeping.
public class FileStore
{
    private readonly string storeDir;

    public FileStore(string label)
    {
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        storeDir = Path.Combine(app_data_dir, "ClipboardDaemon", $"filestore{label}");
        Directory.CreateDirectory(storeDir);
    }

    public string GetPath(string hash) => Path.Combine(storeDir, hash);

    // Used while a file's chunks are still arriving — not yet verified/complete.
    public string GetTempPath(string hash) => Path.Combine(storeDir, $"{hash}.partial");

    public bool Exists(string hash) => File.Exists(GetPath(hash));

    public void Delete(string hash)
    {
        string path = GetPath(hash);
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }
}
