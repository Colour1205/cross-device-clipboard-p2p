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
    private static void HandleMessage(
        string msg,
        ref string? other_device_id,
        PeerConnection conn,
        ConcurrentDictionary<string, PeerConnection> connectionsByDeviceId,
        ClipboardSync clipboardSync,
        HistoryAccess historyAccess,
        TrustStore trustStore)
    {
        var envelope = JsonSerializer.Deserialize<Envelope>(msg);
        if (envelope == null)
        {
            Console.WriteLine("Received invalid message from peer."); // debug
            return;
        }

        if (envelope.Type == "entry")
        {
            var entry = JsonSerializer.Deserialize<ClipboardEntry>(envelope.Payload);
            if (entry == null)
            {
                Console.WriteLine("Received invalid message from peer."); // debug
                return;
            }
            if (!SigningService.Verify(entry, entry.DeviceId) || !trustStore.IsTrusted(entry.DeviceId))
            {
                Console.WriteLine("Received message with invalid signature from peer.");
                return;
            }
            // an "entry" message is always self-originated by the sender, so this is
            // the one place it's actually safe to learn who this connection belongs to
            other_device_id = entry.DeviceId;
            connectionsByDeviceId[entry.DeviceId] = conn;

            clipboardSync.addToQueue(entry.Content, entry.Type);
            historyAccess.addToHistory(entry);
        }
        else if (envelope.Type == "history_batch")
        {
            var entries = JsonSerializer.Deserialize<List<ClipboardEntry>>(envelope.Payload);
            if (entries == null)
            {
                Console.WriteLine("Received invalid message from peer."); // debug
                return;
            }
            foreach (var entry in entries)
            {
                if (!SigningService.Verify(entry, entry.DeviceId) || !trustStore.IsTrusted(entry.DeviceId))
                {
                    Console.WriteLine("Received message with invalid signature from peer.");
                    continue; // skip just this bad entry, keep processing the rest of the batch
                }
                // NOTE: deliberately NOT setting other_device_id here — a batch entry can
                // have originated from a different device than the one we're connected to
                // (history accumulates entries relayed from across the whole mesh).
                if (historyAccess.addToHistory(entry)) // true only if genuinely new, not a duplicate
                {
                    clipboardSync.addToQueue(entry.Content, entry.Type);
                }
            }
        }
        else
        {
            Console.WriteLine("Received message with unknown type from peer.");
            return;
        }
    }

    private static void SendHistoryBatch(PeerConnection conn, HistoryAccess historyAccess)
    {
        var history = historyAccess.GetHistory();
        var envelope = new Envelope("history_batch", JsonSerializer.Serialize(history));
        var json = JsonSerializer.Serialize(envelope);
        _ = conn.Send(json);
    }
    [STAThread]
    static async Task Main(String[] args)
    {
        string label = args.Length > 0 ? args[0] : "default";
        string port = args.Length > 1 ? args[1] : "52388";
        string? trustedKeyToAdd = args.Length > 2 ? args[2] : null;

        var identity = new DeviceIdentity(label);
        var historyAccess = new HistoryAccess(label);
        TrustStore trustStore = new TrustStore(label);
        Console.WriteLine($"Device ID (public key): {identity.GetPublicKey()}");

        if (trustedKeyToAdd != null)
        {
            trustStore.Trust(trustedKeyToAdd);
        }

        ConcurrentDictionary<string, PeerConnection> connectionsByDeviceId = new ConcurrentDictionary<string, PeerConnection>();

        // clipboard watcher
        var clipboardSync = new ClipboardSync();
        clipboardSync.ClipboardChanged += content =>
        {
            var entry = new ClipboardEntry(content.content, content.type, identity.GetPublicKey(), DateTime.UtcNow);
            var signedEntry = SigningService.Sign(entry, identity);
            var envelope = new Envelope("entry", JsonSerializer.Serialize(signedEntry));
            var json = JsonSerializer.Serialize(envelope);
            foreach (var conn in connectionsByDeviceId.Values)
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

                // send history batch on connection
                SendHistoryBatch(conn, historyAccess);
                
                string? other_device_id = null;
                conn.MessageReceived += msg =>
                {
                    HandleMessage(msg, ref other_device_id, conn, connectionsByDeviceId, clipboardSync, historyAccess, trustStore);
                };

                conn.Disconnected += () =>
                {
                    connectionsByDeviceId.TryRemove(other_device_id, out _);
                };
                _ = conn.Listen();
            }

        });




        Discovery discovery = new Discovery();

        discovery.PeerDiscovered += async (other_device_id, sender, other_port) =>
        {
            // connect only when the other device's public key is "smaller" than this device's public key (to avoid duplicate connections)
            // connect only if the other device is in the trust store
            if (!connectionsByDeviceId.ContainsKey(other_device_id) && other_device_id.CompareTo(identity.GetPublicKey()) < 0
            && trustStore.IsTrusted(other_device_id))
            {
                Console.WriteLine($"Discovered peer {other_device_id} at {other_port}");
                // connect to the peer
                TcpClient client = new TcpClient();
                await client.ConnectAsync(sender, other_port);
                var conn = new PeerConnection(client);
                string? connectedDeviceId = other_device_id;
                connectionsByDeviceId[other_device_id] = conn;

                // send history batch on connection
                SendHistoryBatch(conn, historyAccess);

                // message received
                conn.MessageReceived += msg =>
                {
                    HandleMessage(msg, ref connectedDeviceId, conn, connectionsByDeviceId, clipboardSync, historyAccess, trustStore);
                };
                _ = conn.Listen();

                conn.Disconnected += () =>
                {
                    connectionsByDeviceId.TryRemove(other_device_id, out _);
                };
            }

        };
        await discovery.Start(identity.GetPublicKey(), int.Parse(port));
    }
}
