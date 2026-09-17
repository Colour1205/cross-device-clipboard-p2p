// STEP 8:
// Persist clipboard history locally (start with a simple JSON file on disk;
// a real database like SQLite can come later once the shape is proven out).

namespace ClipboardDaemon.Storage;

public class HistoryAccess
{
    private const int MaxHistoryItems = 25;

    private List<ClipboardEntry> inMemoryHistory = new List<ClipboardEntry>();
    private string history_path;
    private readonly FileStore fileStore;

    public HistoryAccess(string label, FileStore fileStore)
    {
        this.fileStore = fileStore;
        // build clipboard entry from file
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        history_path = Path.Combine(app_data_dir, "ClipboardDaemon", $"history{label}.json");
        Directory.CreateDirectory(Path.Combine(app_data_dir, "ClipboardDaemon"));
        if (File.Exists(history_path))
        {
            try
            {
                string json = File.ReadAllText(history_path);
                inMemoryHistory = System.Text.Json.JsonSerializer.Deserialize<List<ClipboardEntry>>(json) ?? new List<ClipboardEntry>();
            }
            catch (System.Text.Json.JsonException ex)
            {
                Console.WriteLine($"Could not load history ({ex.Message}) — starting with empty history.");
                inMemoryHistory = new List<ClipboardEntry>();
            }
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
        TrimToLimit();
        saveHistory();
        return true;
    }

    // Oldest-first eviction once we're over the cap. For a file entry, this
    // also deletes its backing blob from FileStore — otherwise disk usage
    // would grow forever even though the history record itself is capped.
    private void TrimToLimit()
    {
        while (inMemoryHistory.Count > MaxHistoryItems)
        {
            var oldest = inMemoryHistory.OrderBy(e => e.Timestamp).First();
            inMemoryHistory.Remove(oldest);

            if (oldest.Type == "file")
            {
                try
                {
                    var payload = System.Text.Json.JsonSerializer.Deserialize<FilePayload>(oldest.Content);
                    if (payload != null)
                    {
                        fileStore.Delete(payload.FileHash);
                    }
                }
                catch (System.Text.Json.JsonException)
                {
                    // malformed descriptor — nothing coherent to clean up, just drop the record
                }
            }
        }
    }

    public Boolean saveHistory()
    {
        string json = System.Text.Json.JsonSerializer.Serialize(inMemoryHistory);
        File.WriteAllText(history_path, json);
        return true;
    }
    public Boolean clearHistory()
    {
        inMemoryHistory.Clear();
        saveHistory();
        return true;
    }

    public Boolean isEntryInHistory(ClipboardEntry entry)
    {
        return inMemoryHistory.Contains(entry);
    }
}
