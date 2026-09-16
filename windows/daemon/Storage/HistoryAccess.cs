// STEP 8:
// Persist clipboard history locally (start with a simple JSON file on disk;
// a real database like SQLite can come later once the shape is proven out).

namespace ClipboardDaemon.Storage;

public class HistoryAccess
{
    private List<ClipboardEntry> inMemoryHistory = new List<ClipboardEntry>();
    private string history_path;
    public HistoryAccess(string label)
    {
        // build clipboard entry from file
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        history_path = Path.Combine(app_data_dir, "ClipboardDaemon", $"history{label}.json");
        Directory.CreateDirectory(Path.Combine(app_data_dir, "ClipboardDaemon"));
        if (File.Exists(history_path))
        {
            string json = File.ReadAllText(history_path);
            inMemoryHistory = System.Text.Json.JsonSerializer.Deserialize<List<ClipboardEntry>>(json) ?? new List<ClipboardEntry>();
        }
        else
        {
            inMemoryHistory = new List<ClipboardEntry>();
        }
    }
    public List<ClipboardEntry> GetHistory()
    {
        return inMemoryHistory;
    }
    /*
    merges history from peer into local history
    return True if operation succeeded, False otherwise
    */
    public Boolean addToHistory(ClipboardEntry entry)
    {
        if (inMemoryHistory.Contains(entry))
        {
            return false; // duplicate entry
        }
        inMemoryHistory.Add(entry);
        saveHistory();
        return true;
    }
    public Boolean saveHistory()
    {
        string json = System.Text.Json.JsonSerializer.Serialize(inMemoryHistory);
        File.WriteAllText(history_path, json);
        return true;
    }
}
