using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using ClipboardDaemon.Identity;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Clipboard;

class Program
{
    [STAThread]
    static async Task Main(String[] args)
    {
        string label = args.Length > 0 ? args[0] : "default";
        string port = args.Length > 1 ? args[1] : "52388";

        var identity = new DeviceIdentity(label);
        Console.WriteLine($"public key: {identity.GetPublicKeyBase64()}");

        ConcurrentBag<PeerConnection> connections = new ConcurrentBag<PeerConnection>();

        // clipboard watcher
        var clipboardSync = new ClipboardSync();
        clipboardSync.ClipboardChanged += text =>
        {
            Console.WriteLine($"clipboard changed: {text}");
            foreach (var conn in connections)
            {
                _ = conn.Send(text);
            }
        };
#pragma warning disable CS4014


        Thread thisThread = new Thread(() =>
        {
            clipboardSync.Watch();
        });

        thisThread.SetApartmentState(ApartmentState.STA);
        thisThread.IsBackground = true;
        thisThread.Start();



        /* receiving connections */
        Task.Run(async () =>
        {
            TcpListener tcpListener = new TcpListener(IPAddress.Any, int.Parse(port));
            tcpListener.Start();
            while (true)
            {
                var client = await tcpListener.AcceptTcpClientAsync();
                var conn = new PeerConnection(client); // wrap each connection in a PeerConnection object
                conn.MessageReceived += msg =>
                {
                    Console.WriteLine($"peer says: {msg}");
                    clipboardSync.addToQueue(msg);
                };
                _ = conn.Listen(); // fire-and-forget
                connections.Add(conn);

            }

        });


        var connectedPeer = new HashSet<string>();

        Discovery discovery = new Discovery();
        discovery.PeerDiscovered += async (other_device_id, sender, other_port) =>
        {
            Console.WriteLine($"discovered peer: {other_device_id} at {sender}:{other_port}");
            // connect only when the other device's public key is "smaller" than this device's public key (to avoid duplicate connections)
            if (!connectedPeer.Contains(other_device_id) && other_device_id.CompareTo(identity.GetPublicKeyBase64()) < 0)
            {
                connectedPeer.Add(other_device_id);
                // connect to the peer
                TcpClient client = new TcpClient();
                await client.ConnectAsync(sender, other_port);
                var conn = new PeerConnection(client);
                conn.MessageReceived += msg =>
                {
                    Console.WriteLine($"peer says: {msg}");
                    clipboardSync.addToQueue(msg);
                };
                _ = conn.Listen(); // fire-and-forget
                _ = conn.Send("Hello from " + identity.GetPublicKeyBase64());
                connections.Add(conn);
            }
        };
        await discovery.Start(identity.GetPublicKeyBase64(), int.Parse(port));
    }
}
