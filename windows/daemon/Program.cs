using System.Net;
using System.Net.Sockets;
using ClipboardDaemon.Clipboard;
using ClipboardDaemon.Identity;
using ClipboardDaemon.Networking;

class Program
{
    [STAThread]
    static async Task Main(String[] args)
    {
        string label = args.Length > 0 ? args[0] : "default";
        string port = args.Length > 1 ? args[1] : "52388";

        var identity = new DeviceIdentity(label);
        Console.WriteLine($"public key: {identity.GetPublicKeyBase64()}");

        // clipboard watcher
        var watcher = new ClipboardWatcher();
        watcher.ClipboardChanged += text => Console.WriteLine($"changed: {text}");
        #pragma warning disable CS4014 // Because this call is not awaited, execution of the current method continues before the call is completed
        Task.Run(() => watcher.Start());
        Task.Run(async () =>
{
            TcpListener listener = new TcpListener(IPAddress.Any, int.Parse(port));
            listener.Start();
            while (true)
            {
                TcpClient incoming = await listener.AcceptTcpClientAsync();
                var conn = new PeerConnection(incoming);
                conn.MessageReceived += msg => Console.WriteLine($"peer says: {msg}");
                _ = conn.Listen(); // fire-and-forget, same idea as before
            }
        });

        if (args.Length > 2)
        {
            Task.Run(async () => 
            {
                TcpClient outgoing = new TcpClient();
                await outgoing.ConnectAsync("localhost", int.Parse(args[2]));
                var conn = new PeerConnection(outgoing);
                conn.MessageReceived += msg => Console.WriteLine($"peer says: {msg}");
                _ = conn.Listen(); // fire-and-forget, same idea as before
                await conn.Send("hello from device 2");
            });
        }


        Discovery discovery = new Discovery();
        await discovery.Start(identity.GetPublicKeyBase64());
    }
}
