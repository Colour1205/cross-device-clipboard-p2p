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

    // Dials out to a peer at a known address and wires it up exactly the same
    // way regardless of how that address was found — LAN discovery or a
    // cached off-LAN (Tailscale) address from the trust store.
    private static async Task ConnectToPeer(
        string peerDeviceId,
        string address,
        int port,
        ConcurrentDictionary<string, PeerConnection> connectionsByDeviceId,
        ClipboardSync clipboardSync,
        HistoryAccess historyAccess,
        TrustStore trustStore,
        CancellationToken cancellationToken = default)
    {
        TcpClient client = new TcpClient();
        await client.ConnectAsync(address, port, cancellationToken);
        var conn = new PeerConnection(client);
        string? connectedDeviceId = peerDeviceId;
        connectionsByDeviceId[peerDeviceId] = conn;

        SendHistoryBatch(conn, historyAccess);

        conn.MessageReceived += msg =>
        {
            HandleMessage(msg, ref connectedDeviceId, conn, connectionsByDeviceId, clipboardSync, historyAccess, trustStore);
        };
        _ = conn.Listen();

        conn.Disconnected += () =>
        {
            connectionsByDeviceId.TryRemove(peerDeviceId, out _);
        };
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
        var passphraseKeyStore = new PassphraseKeyStore(label);
        Console.WriteLine($"Device ID (public key): {identity.GetPublicKey()}");

        if (trustedKeyToAdd != null)
        {
            trustStore.Trust(trustedKeyToAdd);
        }

        // local IPC for the tray app (QR pairing, passcode setup, etc.)
        var ipcServer = new IpcServer(label);
        ipcServer.RequestReceived += request =>
        {
            if (request.Command == "get_public_key")
            {
                return new IpcResponse(true, identity.GetPublicKey());
            }
            else if (request.Command == "get_pairing_info")
            {
                var pairingInfo = new PairingInfo(identity.GetPublicKey(), TailscaleHelper.GetOwnTailscaleIp());
                return new IpcResponse(true, JsonSerializer.Serialize(pairingInfo));
            }
            else if (request.Command == "has_passphrase")
            {
                return new IpcResponse(true, passphraseKeyStore.HasPassphrase.ToString());
            }
            else if (request.Command == "set_passphrase" && request.Payload != null)
            {
                passphraseKeyStore.SetPassphrase(request.Payload);
                return new IpcResponse(true, "passphrase set");
            }
            else if (request.Command == "trust_device" && request.Payload != null)
            {
                // accept either the new {PublicKey, Address} pairing payload, or a
                // bare key (e.g. the CLI --trust flow, or an older tray build)
                PairingInfo? pairingInfo = null;
                try
                {
                    pairingInfo = JsonSerializer.Deserialize<PairingInfo>(request.Payload);
                }
                catch (JsonException) { /* not JSON — fall through to bare-key handling below */ }

                if (pairingInfo != null && !string.IsNullOrWhiteSpace(pairingInfo.PublicKey))
                {
                    trustStore.Trust(pairingInfo.PublicKey, pairingInfo.Address);
                }
                else
                {
                    trustStore.Trust(request.Payload);
                }
                return new IpcResponse(true, "trusted");
            }
            else
            {
                return new IpcResponse(false, "unknown command");
            }
        };
        _ = Task.Run(() => ipcServer.Start());

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
                    if (other_device_id != null)
                    {
                        connectionsByDeviceId.TryRemove(other_device_id, out _);
                    }
                };
                _ = conn.Listen();
            }

        });




        Discovery discovery = new Discovery();

        discovery.PeerDiscovered += async (other_device_id, sender, other_port, proof) =>
        {
            // auto-trust: if this device wasn't already trusted, but it proved
            // knowledge of the same passphrase we have configured, trust it now —
            // an alternative to manual QR/key pairing for "these are all my own devices".
            // Excludes our own id: UDP broadcasts loop back to the sender on
            // localhost, so without this check a device would "auto-trust" itself.
            if (other_device_id != identity.GetPublicKey()
                && !trustStore.IsTrusted(other_device_id) && proof != null && passphraseKeyStore.HasPassphrase
                && PassphraseAuth.VerifyProof(passphraseKeyStore.GetKey()!, other_device_id, proof))
            {
                Console.WriteLine($"Auto-trusting {other_device_id} — proved knowledge of shared passphrase");
                trustStore.Trust(other_device_id);
            }

            // connect only when the other device's public key is "smaller" than this device's public key (to avoid duplicate connections)
            // connect only if the other device is in the trust store
            if (!connectionsByDeviceId.ContainsKey(other_device_id) && other_device_id.CompareTo(identity.GetPublicKey()) < 0
            && trustStore.IsTrusted(other_device_id))
            {
                Console.WriteLine($"Discovered peer {other_device_id} at {other_port}");
                try
                {
                    await ConnectToPeer(other_device_id, sender.ToString(), other_port, connectionsByDeviceId, clipboardSync, historyAccess, trustStore);
                }
                catch (Exception)
                {
                    // peer wasn't actually reachable — ignore, we'll hear its next beacon
                }
            }

        };

        // off-LAN reconnect loop: for trusted peers we have a cached address for
        // (e.g. Tailscale, learned at pairing time) but aren't currently connected
        // to — LAN discovery can't find these, so we have to proactively retry
        _ = Task.Run(async () =>
        {
            while (true)
            {
                var attempts = trustStore.GetTrustedDevicesWithAddress()
                    .Where(device => !connectionsByDeviceId.ContainsKey(device.PublicKey)
                        && device.PublicKey.CompareTo(identity.GetPublicKey()) < 0)
                    .Select(async device =>
                    {
                        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                        try
                        {
                            await ConnectToPeer(device.PublicKey, device.Address!, int.Parse(port), connectionsByDeviceId, clipboardSync, historyAccess, trustStore, cts.Token);
                        }
                        catch (Exception)
                        {
                            // not reachable via this address right now — retry next cycle
                        }
                    });

                // run every attempt concurrently, so one offline peer's 5s timeout
                // doesn't delay checking the others
                await Task.WhenAll(attempts);
                await Task.Delay(TimeSpan.FromSeconds(30));
            }
        });

        await discovery.Start(identity.GetPublicKey(), int.Parse(port), () =>
            passphraseKeyStore.HasPassphrase
                ? PassphraseAuth.ComputeProof(passphraseKeyStore.GetKey()!, identity.GetPublicKey())
                : null);
    }
}
