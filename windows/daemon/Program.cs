using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using ClipboardDaemon.Identity;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Clipboard;
using ClipboardDaemon.Storage;
using System.Text.Json;
using ClipboardDaemon.Crypto;

class Program
{
    [STAThread]
    static async Task Main(String[] args)
    {
        string label = args.Length > 0 ? args[0] : "default";
        string port = args.Length > 1 ? args[1] : "52388";
        string? trustedKeyToAdd = args.Length > 2 ? args[2] : null;

        var identity = new DeviceIdentity(label);
        var historyAccess = new HistoryAccess(label);
        TrustStore trustStore = new TrustStore(label);

        if (trustedKeyToAdd != null)
        {
            trustStore.Trust(trustedKeyToAdd);
        }

        ConcurrentBag<PeerConnection> connections = new ConcurrentBag<PeerConnection>();

        // clipboard watcher
        var clipboardSync = new ClipboardSync();
        clipboardSync.ClipboardChanged += content =>
        {
            var entry = new ClipboardEntry(content.content, content.type, identity.GetPublicKey(), DateTime.UtcNow);
            var signedEntry = SigningService.Sign(entry, identity);
            string json = JsonSerializer.Serialize(signedEntry);
            foreach (var conn in connections)
            {
                _ = conn.Send(json);
            }
            historyAccess.addToHistory(signedEntry);
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
                    var entry = JsonSerializer.Deserialize<ClipboardEntry>(msg);
                    if (entry == null)
                    {
                        Console.WriteLine("Received invalid message from peer."); // debug
                        return;
                    }
                    Console.WriteLine($"peer says: {entry.Content}");
                    if (!SigningService.Verify(entry, entry.DeviceId) || !trustStore.IsTrusted(entry.DeviceId))
                    {
                        Console.WriteLine("Received message with invalid signature from peer.");
                        return;
                    }
                    clipboardSync.addToQueue(entry.Content, entry.Type);
                    historyAccess.addToHistory(entry);
                };
                _ = conn.Listen(); // fire-and-forget
                connections.Add(conn);

            }

        });


        var connectedPeer = new HashSet<string>();

        Discovery discovery = new Discovery();

        discovery.PeerDiscovered += async (other_device_id, sender, other_port) =>
        {
            // connect only when the other device's public key is "smaller" than this device's public key (to avoid duplicate connections)
            // connect only if the other device is in the trust store
            if (!connectedPeer.Contains(other_device_id) && other_device_id.CompareTo(identity.GetPublicKey()) < 0
            && trustStore.IsTrusted(other_device_id))
            {
                Console.WriteLine($"Discovered peer {other_device_id} at {sender}:{other_port}");
                connectedPeer.Add(other_device_id);
                // connect to the peer
                TcpClient client = new TcpClient();
                await client.ConnectAsync(sender, other_port);
                var conn = new PeerConnection(client);
                conn.MessageReceived += msg =>
                {
                    var entry = JsonSerializer.Deserialize<ClipboardEntry>(msg);
                    if (entry == null)
                    {
                        Console.WriteLine("Received invalid message from peer."); // debug
                        return;
                    }
                    Console.WriteLine($"peer says: {entry.Content}");
                    if (!SigningService.Verify(entry, entry.DeviceId) || !trustStore.IsTrusted(entry.DeviceId))
                    {
                        Console.WriteLine("Received message with invalid signature from peer.");
                        return;
                    }
                    clipboardSync.addToQueue(entry.Content, entry.Type);
                    historyAccess.addToHistory(entry);
                };
                _ = conn.Listen();
                connections.Add(conn);
            }
        };
        await discovery.Start(identity.GetPublicKey(), int.Parse(port));
    }
}
