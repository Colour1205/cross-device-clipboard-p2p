using ClipboardDaemon.Clipboard;
using ClipboardDaemon.Identity;
using ClipboardDaemon.Networking;

class Program
{
    [STAThread]
    static async Task Main(String[] args)
    {
        string label = args.Length > 0 ? args[0] : "default";
        var identity = new DeviceIdentity(label);
        Console.WriteLine($"public key: {identity.GetPublicKeyBase64()}");

        // clipboard watcher
        var watcher = new ClipboardWatcher();
        watcher.ClipboardChanged += text => Console.WriteLine($"changed: {text}");
        Task.Run(() => watcher.Start());

        Discovery discovery = new Discovery();
        await discovery.Start(identity.GetPublicKeyBase64());
    }
}
