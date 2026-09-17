// STEP 2 & 3:
// - Step 2: read the current Windows clipboard content and print it.
// - Step 3: detect when the clipboard CHANGES (event-driven, not polling),
//   and fire your own event/callback with the new content.

namespace ClipboardDaemon.Clipboard;

using System.Collections.Concurrent;

// What Content holds for type == "file": the original name, plus the raw
// file bytes, base64-encoded — same "Content is just a string, meaning
// depends on Type" pattern as everything else, no ClipboardEntry changes needed.
public record FilePayload(string FileName, string DataBase64);

public class ClipboardSync
{
    private const long MaxFileBytes = 1024L * 1024 * 1024; // 1GB — our transport buffers a whole file in memory at once (no chunked streaming), so this is a real memory ceiling, not just a network one

    BlockingCollection<(string content, string type)> _pendingSets = new BlockingCollection<(string content, string type)>();
    private string? _lastKnownHash;
    public event Action<(string content, string type)>? ClipboardChanged;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern uint GetClipboardSequenceNumber();

    public void Watch()
    {
        long last_sequence_num = GetClipboardSequenceNumber();

        var timer = new System.Windows.Forms.Timer();
        timer.Interval = 500;
        timer.Tick += (s, e) =>
        {
                        long curr_sequence_num = GetClipboardSequenceNumber();
            if (curr_sequence_num != last_sequence_num)
            {
                try{
                    bool is_img = System.Windows.Forms.Clipboard.ContainsImage();
                    bool is_text = System.Windows.Forms.Clipboard.ContainsText();
                    bool is_aud = System.Windows.Forms.Clipboard.ContainsAudio();
                    bool is_drop_lst = System.Windows.Forms.Clipboard.ContainsFileDropList();

                    last_sequence_num = curr_sequence_num;

                    // check image before text: a copied bitmap is the thing the
                    // user actually wants synced, even if Windows also exposes
                    // some auto-generated text representation alongside it
                    if (is_img)
                    {
                        using var image = System.Windows.Forms.Clipboard.GetImage();
                        if (image != null)
                        {
                            using var ms = new MemoryStream();
                            image.Save(ms, System.Drawing.Imaging.ImageFormat.Png);
                            byte[] imageBytes = ms.ToArray();
                            string hash = ComputeHash(imageBytes);
                            if (hash != _lastKnownHash)
                            {
                                _lastKnownHash = hash;
                                ClipboardChanged?.Invoke((Convert.ToBase64String(imageBytes), "image"));
                            }
                        }
                    }
                    else if (is_text)
                    {
                        string text = System.Windows.Forms.Clipboard.GetText();
                        string hash = ComputeHash(System.Text.Encoding.UTF8.GetBytes(text));
                        if (hash != _lastKnownHash)
                        {
                            _lastKnownHash = hash;
                            ClipboardChanged?.Invoke((System.Windows.Forms.Clipboard.GetText(), "text"));
                        }
                    }
                    else if (is_drop_lst)
                    {
                        var files = System.Windows.Forms.Clipboard.GetFileDropList();
                        // v1 scope: single file only — first entry, rest ignored
                        if (files.Count > 0 && files[0] != null)
                        {
                            string path = files[0]!;
                            var fileInfo = new FileInfo(path);
                            if (!fileInfo.Exists)
                            {
                                Console.WriteLine($"skipping file drop, not a readable file: {path}");
                            }
                            else if (fileInfo.Length > MaxFileBytes)
                            {
                                Console.WriteLine($"skipping file drop, too large to sync ({fileInfo.Length} bytes, limit {MaxFileBytes}): {path}");
                            }
                            else
                            {
                                byte[] fileBytes = File.ReadAllBytes(path);
                                string hash = ComputeHash(fileBytes);
                                if (hash != _lastKnownHash)
                                {
                                    _lastKnownHash = hash;
                                    var payload = new FilePayload(fileInfo.Name, Convert.ToBase64String(fileBytes));
                                    ClipboardChanged?.Invoke((System.Text.Json.JsonSerializer.Serialize(payload), "file"));
                                }
                            }
                        }
                    }
                    else
                    {
                        // Audio has no meaningful cross-device representation the same
                        // way files/images do — skip rather than half-implement it.
                        Console.WriteLine($"unsupported clipboard change: audio={is_aud}");
                    }
                } catch (Exception)
                {
                    Console.WriteLine($"clipboard busy, will retry next poll");
                }
            }
            // push content from the queue to the clipboard
            if (_pendingSets.TryTake(out var pendingSet))
            try{
                setContent(pendingSet.content, pendingSet.type);
            }
            catch (Exception)
            {
                Console.WriteLine($"clipboard busy, dropping this peer update for now");
            }
        };

        timer.Start();
        System.Windows.Forms.Application.Run();
    }

    public void addToQueue(string content, string type = "text")
    {
        _pendingSets.Add((content, type));
    }

    public void setContent(String content, string type = "text")
    {
        if (type == "text")
        {
            _lastKnownHash = ComputeHash(System.Text.Encoding.UTF8.GetBytes(content));
            System.Windows.Forms.Clipboard.SetText(content);
        }
        else if (type == "image")
        {
            byte[] imageBytes = Convert.FromBase64String(content);
            _lastKnownHash = ComputeHash(imageBytes);
            using var ms = new MemoryStream(imageBytes);
            using var image = System.Drawing.Image.FromStream(ms);
            System.Windows.Forms.Clipboard.SetImage(image);
        }
        else if (type == "file")
        {
            var payload = System.Text.Json.JsonSerializer.Deserialize<FilePayload>(content);
            if (payload == null) return;

            byte[] fileBytes = Convert.FromBase64String(payload.DataBase64);
            _lastKnownHash = ComputeHash(fileBytes);

            string receivedDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "ClipboardDaemon", "ReceivedFiles");
            Directory.CreateDirectory(receivedDir);

            string destPath = GetNonCollidingPath(receivedDir, payload.FileName);
            File.WriteAllBytes(destPath, fileBytes);

            var fileList = new System.Collections.Specialized.StringCollection();
            fileList.Add(destPath);
            System.Windows.Forms.Clipboard.SetFileDropList(fileList);
        }
        else
        {
            throw new NotImplementedException($"Clipboard type '{type}' is not supported yet.");
        }
    }

    private string ComputeHash(byte[] data)
{
    return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(data));
}

    // If "photo.jpg" already exists, try "photo (1).jpg", "photo (2).jpg", etc.
    private string GetNonCollidingPath(string dir, string fileName)
    {
        string candidate = Path.Combine(dir, fileName);
        if (!File.Exists(candidate)) return candidate;

        string nameOnly = Path.GetFileNameWithoutExtension(fileName);
        string ext = Path.GetExtension(fileName);
        int counter = 1;
        do
        {
            candidate = Path.Combine(dir, $"{nameOnly} ({counter}){ext}");
            counter++;
        } while (File.Exists(candidate));

        return candidate;
    }
}
