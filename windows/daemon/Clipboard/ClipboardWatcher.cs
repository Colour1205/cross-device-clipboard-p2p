// STEP 2 & 3:
// - Step 2: read the current Windows clipboard content and print it.
// - Step 3: detect when the clipboard CHANGES (event-driven, not polling),
//   and fire your own event/callback with the new content.

namespace ClipboardDaemon.Clipboard;

public class ClipboardWatcher
{
    public event Action<string>? ClipboardChanged;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern uint GetClipboardSequenceNumber();

    public void Start()
    {
        long last_sequence_num = GetClipboardSequenceNumber();
        while (true)
        {
            long curr_sequence_num = GetClipboardSequenceNumber();
            if (curr_sequence_num != last_sequence_num)
            {
                last_sequence_num = curr_sequence_num;

                bool is_img = System.Windows.Forms.Clipboard.ContainsImage();
                bool is_text = System.Windows.Forms.Clipboard.ContainsText();
                bool is_aud = System.Windows.Forms.Clipboard.ContainsAudio();
                bool is_drop_lst = System.Windows.Forms.Clipboard.ContainsFileDropList();

                if (is_text)
                {
                    ClipboardChanged?.Invoke(System.Windows.Forms.Clipboard.GetText());
                }
                else
                {
                    Console.WriteLine($"non-text change: img={is_img} audio={is_aud} files={is_drop_lst}");
                }
            }
            System.Threading.Thread.Sleep(500);
        }
    }
}
