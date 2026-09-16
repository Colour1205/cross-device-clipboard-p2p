// STEP 2 & 3:
// - Step 2: read the current Windows clipboard content and print it.
// - Step 3: detect when the clipboard CHANGES (event-driven, not polling),
//   and fire your own event/callback with the new content.

namespace ClipboardDaemon.Clipboard;

using System.Collections.Concurrent;

public class ClipboardSync
{
    BlockingCollection<(string content, string type)> _pendingSets = new BlockingCollection<(string content, string type)>();
    private string? _lastKnownHash;
    public event Action<(string content, string type)>? ClipboardChanged;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern uint GetClipboardSequenceNumber();

    public void Watch()
    {
        long last_sequence_num = GetClipboardSequenceNumber();
        while (true)
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

                    if (is_text)
                    {
                        string text = System.Windows.Forms.Clipboard.GetText();
                        string hash = ComputeHash(System.Text.Encoding.UTF8.GetBytes(text));
                        if (hash != _lastKnownHash)
                        {
                            _lastKnownHash = hash;
                            ClipboardChanged?.Invoke((System.Windows.Forms.Clipboard.GetText(), "text"));
                        }
                    }
                    else
                    {
                        // TODO handle other formats
                        Console.WriteLine($"non-text change: img={is_img} audio={is_aud} files={is_drop_lst}");
                    }
                } catch (Exception ex)
                {
                    Console.WriteLine($"clipboard busy, will retry next poll");
                }
            }
            // push content from the queue to the clipboard
            if (_pendingSets.TryTake(out var pendingSet))
            try{
                setContent(pendingSet.content, pendingSet.type);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"clipboard busy, dropping this peer update for now");
            }
            System.Threading.Thread.Sleep(500);
        }
    }

    public void addToQueue(string content, string type = "text")
    {
        _pendingSets.Add((content, type));
    }

    public void setContent(String content, string type = "text")
    {
        _lastKnownHash = ComputeHash(System.Text.Encoding.UTF8.GetBytes(content));
        if (type == "text")
        {
            System.Windows.Forms.Clipboard.SetText(content);
        }
        else
        {
            throw new NotImplementedException("Only text clipboard is supported for now.");
        }
    }

    private string ComputeHash(byte[] data)
{
    return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(data));
}
}
