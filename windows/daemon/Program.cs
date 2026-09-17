using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using ClipboardDaemon.Identity;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Clipboard;
using ClipboardDaemon.Storage;
using System.Text.Json;
using ClipboardDaemon.Crypto;

class Program
{
    // Bundles the two pieces of state a chunked file transfer needs while
    // it's in progress: the still-open write stream for each hash currently
    // being received, and any entry that arrived (and was verified) before
    // its bytes finished streaming in, waiting to be applied once they do.
    private class FileTransferState
    {
        public ConcurrentDictionary<string, FileStream> InProgressWrites = new();
        public ConcurrentDictionary<string, ClipboardEntry> PendingEntries = new();
    }

    private static void HandleMessage(
        string msg,
        PeerConnection conn,
        ConcurrentDictionary<string, PeerConnection> connectionsByDeviceId,
        ClipboardSync clipboardSync,
        HistoryAccess historyAccess,
        TrustStore trustStore,
        FileStore fileStore,
        FileTransferState fileTransferState)
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

            if (entry.Type == "file")
            {
                HandleIncomingFileEntry(entry, clipboardSync, fileStore, fileTransferState, connectionsByDeviceId);
            }
            else
            {
                clipboardSync.addToQueue(entry.Content, entry.Type);
            }
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
                if (historyAccess.addToHistory(entry)) // true only if genuinely new, not a duplicate
                {
                    if (entry.Type == "file")
                    {
                        // same handling as a live entry now: if we don't have the
                        // bytes, ask the whole network for them, not just whoever
                        // we're reconciling with
                        HandleIncomingFileEntry(entry, clipboardSync, fileStore, fileTransferState, connectionsByDeviceId);
                    }
                    else
                    {
                        clipboardSync.addToQueue(entry.Content, entry.Type);
                    }
                }
            }
        }
        else if (envelope.Type == "file_chunk")
        {
            HandleFileChunk(envelope.Payload, fileStore, fileTransferState, clipboardSync);
        }
        else if (envelope.Type == "file_request")
        {
            HandleFileRequest(envelope.Payload, fileStore, conn);
        }
        else
        {
            Console.WriteLine("Received message with unknown type from peer.");
            return;
        }
    }

    private static void HandleIncomingFileEntry(
        ClipboardEntry entry,
        ClipboardSync clipboardSync,
        FileStore fileStore,
        FileTransferState fileTransferState,
        ConcurrentDictionary<string, PeerConnection> connectionsByDeviceId)
    {
        FilePayload? payload;
        try
        {
            payload = JsonSerializer.Deserialize<FilePayload>(entry.Content);
        }
        catch (JsonException) { payload = null; }

        if (payload == null)
        {
            Console.WriteLine("Received malformed file entry from peer.");
            return;
        }

        if (fileStore.Exists(payload.FileHash))
        {
            // already have these exact bytes locally — apply right away
            clipboardSync.addToQueue(entry.Content, entry.Type);
            return;
        }

        // don't have it yet — remember to apply it once file_chunk messages for
        // this hash finish arriving and verify, and ask every connected peer
        // (not just whoever handed us this entry) whether they have it
        fileTransferState.PendingEntries[payload.FileHash] = entry;
        BroadcastFileRequest(payload.FileHash, connectionsByDeviceId);
    }

    private static void BroadcastFileRequest(string fileHash, ConcurrentDictionary<string, PeerConnection> connectionsByDeviceId)
    {
        var request = new FileRequestMessage(fileHash);
        var envelope = new Envelope("file_request", JsonSerializer.Serialize(request));
        var json = JsonSerializer.Serialize(envelope);
        foreach (var conn in connectionsByDeviceId.Values)
        {
            _ = conn.Send(json);
        }
    }

    private static void HandleFileRequest(string payloadJson, FileStore fileStore, PeerConnection requestingConn)
    {
        FileRequestMessage? request;
        try
        {
            request = JsonSerializer.Deserialize<FileRequestMessage>(payloadJson);
        }
        catch (JsonException) { request = null; }
        if (request == null) return;

        if (fileStore.Exists(request.FileHash))
        {
            _ = StreamFileToPeer(requestingConn, fileStore.GetPath(request.FileHash), request.FileHash);
        }
        // if we don't have it either, just don't respond — the requester
        // already broadcast to everyone else too; someone else might have it
    }

    private static void HandleFileChunk(
        string payloadJson,
        FileStore fileStore,
        FileTransferState fileTransferState,
        ClipboardSync clipboardSync)
    {
        FileChunkMessage? chunk;
        try
        {
            chunk = JsonSerializer.Deserialize<FileChunkMessage>(payloadJson);
        }
        catch (JsonException) { chunk = null; }
        if (chunk == null) return;

        byte[] chunkBytes;
        try
        {
            chunkBytes = Convert.FromBase64String(chunk.DataBase64);
        }
        catch (FormatException) { return; }

        var stream = fileTransferState.InProgressWrites.GetOrAdd(chunk.FileHash, _ =>
            new FileStream(fileStore.GetTempPath(chunk.FileHash), FileMode.Create, FileAccess.Write));

        try
        {
            stream.Write(chunkBytes, 0, chunkBytes.Length);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed writing file chunk ({ex.Message}) — abandoning this transfer.");
            fileTransferState.InProgressWrites.TryRemove(chunk.FileHash, out _);
            stream.Dispose();
            return;
        }

        if (!chunk.IsLast) return;

        stream.Flush();
        stream.Dispose();
        fileTransferState.InProgressWrites.TryRemove(chunk.FileHash, out _);

        string tempPath = fileStore.GetTempPath(chunk.FileHash);
        string actualHash;
        using (var verifyStream = File.OpenRead(tempPath))
        {
            actualHash = Convert.ToHexString(SHA256.HashData(verifyStream));
        }

        if (actualHash != chunk.FileHash)
        {
            // corrupted in transit, or tampered — the signed entry's hash is
            // what we trust, not whatever bytes actually showed up
            Console.WriteLine($"File transfer failed hash verification (expected {chunk.FileHash}, got {actualHash}) — discarding.");
            File.Delete(tempPath);
            fileTransferState.PendingEntries.TryRemove(chunk.FileHash, out _);
            return;
        }

        File.Move(tempPath, fileStore.GetPath(chunk.FileHash), overwrite: true);
        TryFulfillPendingEntry(chunk.FileHash, fileTransferState, clipboardSync);
    }

    // FileStore can gain a blob through more than one path — chunk-stream
    // completion (above), but also a device's own local capture of a file it
    // happens to have independently obtained (e.g. self-detecting the same
    // file another process just applied, on a shared clipboard during local
    // testing — or, in principle, any other future path that populates
    // FileStore). Whichever way a hash becomes available, a pending entry
    // waiting on exactly that hash should get applied — not just when the
    // chunk-reassembly path happens to be the one that completed it.
    private static void TryFulfillPendingEntry(string fileHash, FileTransferState fileTransferState, ClipboardSync clipboardSync)
    {
        if (fileTransferState.PendingEntries.TryRemove(fileHash, out var pendingEntry))
        {
            clipboardSync.addToQueue(pendingEntry.Content, pendingEntry.Type);
        }
    }

    // Reads a file incrementally and sends it as a sequence of file_chunk
    // envelopes — bounded memory (one chunk at a time) regardless of the
    // file's total size, unlike embedding the whole thing in one message.
    private static async Task StreamFileToPeer(PeerConnection conn, string filePath, string fileHash)
    {
        const int chunkSize = 256 * 1024;
        try
        {
            using var stream = File.OpenRead(filePath);
            byte[] buffer = new byte[chunkSize];
            int chunkIndex = 0;
            int bytesRead;
            while ((bytesRead = await stream.ReadAsync(buffer, 0, chunkSize)) > 0)
            {
                bool isLast = stream.Position >= stream.Length;
                byte[] chunkBytes = bytesRead == chunkSize ? buffer : buffer[..bytesRead];
                var chunkMsg = new FileChunkMessage(fileHash, chunkIndex, isLast, Convert.ToBase64String(chunkBytes));
                var envelope = new Envelope("file_chunk", JsonSerializer.Serialize(chunkMsg));
                await conn.Send(JsonSerializer.Serialize(envelope));
                chunkIndex++;
            }
        }
        catch (Exception)
        {
            // peer disconnected mid-transfer, or the source file became
            // unreadable — nothing further to do about it
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
        DeviceIdentity myIdentity,
        ConcurrentDictionary<string, PeerConnection> connectionsByDeviceId,
        ClipboardSync clipboardSync,
        HistoryAccess historyAccess,
        TrustStore trustStore,
        FileStore fileStore,
        FileTransferState fileTransferState,
        CancellationToken cancellationToken = default)
    {
        TcpClient client = new TcpClient();
        await client.ConnectAsync(address, port, cancellationToken);

        var conn = await PeerConnection.CreateAsync(client, myIdentity, trustStore);
        if (conn == null)
        {
            client.Close();
            throw new IOException("Handshake failed, or peer is not trusted");
        }
        if (conn.PeerDeviceId != peerDeviceId)
        {
            // connected, but whoever answered isn't who we meant to reach —
            // refuse rather than silently trusting data from the wrong device
            conn.Close();
            throw new IOException("Connected peer's identity did not match the expected device id");
        }

        connectionsByDeviceId[peerDeviceId] = conn;
        SendHistoryBatch(conn, historyAccess);

        conn.MessageReceived += msg => HandleMessage(msg, conn, connectionsByDeviceId, clipboardSync, historyAccess, trustStore, fileStore, fileTransferState);
        conn.Disconnected += () => connectionsByDeviceId.TryRemove(peerDeviceId, out _);
        _ = conn.Listen();
    }
    [STAThread]
    static async Task Main(String[] args)
    {
        string label = args.Length > 0 ? args[0] : "default";
        string port = args.Length > 1 ? args[1] : "52388";
        string? trustedKeyToAdd = args.Length > 2 ? args[2] : null;

        var identity = new DeviceIdentity(label);
        var fileStore = new FileStore(label);
        var historyAccess = new HistoryAccess(label, fileStore);
        TrustStore trustStore = new TrustStore(label);
        var passphraseKeyStore = new PassphraseKeyStore(label);
        var fileTransferState = new FileTransferState();
        Console.WriteLine($"Device ID (public key): {identity.GetPublicKey()}");

        if (trustedKeyToAdd != null)
        {
            trustStore.Trust(trustedKeyToAdd);
        }

        TrayLauncher.TryStart(label);

        // computed once — Tailscale IPs are stable, and shelling out to the CLI
        // on every 2-second beacon would be wasteful. If Tailscale gets installed
        // while the daemon is already running, a restart picks it up.
        string? ownTailscaleAddress = TailscaleHelper.GetOwnTailscaleIp();

        ConcurrentDictionary<string, PeerConnection> connectionsByDeviceId = new ConcurrentDictionary<string, PeerConnection>();

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
            else if (request.Command == "list_connections")
            {
                return new IpcResponse(true, JsonSerializer.Serialize(connectionsByDeviceId.Keys.ToList()));
            }
            else if (request.Command == "list_trusted")
            {
                return new IpcResponse(true, JsonSerializer.Serialize(trustStore.GetAllTrustedDevices().ToList()));
            }
            else if (request.Command == "untrust_device" && request.Payload != null)
            {
                trustStore.Untrust(request.Payload);
                if (connectionsByDeviceId.TryRemove(request.Payload, out var conn))
                {
                    conn.Close();
                }
                return new IpcResponse(true, "untrusted");
            }
            else
            {
                return new IpcResponse(false, "unknown command");
            }
        };
        _ = Task.Run(() => ipcServer.Start());

        // clipboard watcher
        var clipboardSync = new ClipboardSync(fileStore);
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

            if (content.type == "file" && content.sourceFilePath != null)
            {
                FilePayload? payload = null;
                try { payload = JsonSerializer.Deserialize<FilePayload>(content.content); }
                catch (JsonException) { }

                if (payload != null)
                {
                    if (!fileStore.Exists(payload.FileHash))
                    {
                        try
                        {
                            File.Copy(content.sourceFilePath, fileStore.GetPath(payload.FileHash), overwrite: true);
                        }
                        catch (IOException ex)
                        {
                            Console.WriteLine($"Could not cache file locally ({ex.Message}) — won't be able to stream it to peers.");
                        }
                    }
                    if (fileStore.Exists(payload.FileHash))
                    {
                        foreach (var conn in connectionsByDeviceId.Values)
                        {
                            _ = StreamFileToPeer(conn, fileStore.GetPath(payload.FileHash), payload.FileHash);
                        }
                        // this exact content might already be something we were
                        // waiting on from a peer (e.g. this device independently
                        // captured the same file another connected device just
                        // applied) — fulfill that now rather than leaving it stuck
                        TryFulfillPendingEntry(payload.FileHash, fileTransferState, clipboardSync);
                    }
                }
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

                var conn = await PeerConnection.CreateAsync(client, identity, trustStore);
                if (conn == null)
                {
                    // handshake failed, or whoever connected isn't in our trust
                    // store — refuse at the connection level, not just per-message
                    client.Close();
                    continue;
                }

                connectionsByDeviceId[conn.PeerDeviceId] = conn;
                SendHistoryBatch(conn, historyAccess);

                conn.MessageReceived += msg => HandleMessage(msg, conn, connectionsByDeviceId, clipboardSync, historyAccess, trustStore, fileStore, fileTransferState);
                conn.Disconnected += () => connectionsByDeviceId.TryRemove(conn.PeerDeviceId, out _);
                _ = conn.Listen();
            }

        });




        Discovery discovery = new Discovery();

        discovery.PeerDiscovered += async (other_device_id, sender, other_port, proof, peerAddress) =>
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
                trustStore.Trust(other_device_id, peerAddress);
            }

            // connect only when the other device's public key is "smaller" than this device's public key (to avoid duplicate connections)
            // connect only if the other device is in the trust store
            if (!connectionsByDeviceId.ContainsKey(other_device_id) && other_device_id.CompareTo(identity.GetPublicKey()) < 0
            && trustStore.IsTrusted(other_device_id))
            {
                Console.WriteLine($"Discovered peer {other_device_id} at {other_port}");
                try
                {
                    await ConnectToPeer(other_device_id, sender.ToString(), other_port, identity, connectionsByDeviceId, clipboardSync, historyAccess, trustStore, fileStore, fileTransferState);
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
                            await ConnectToPeer(device.PublicKey, device.Address!, int.Parse(port), identity, connectionsByDeviceId, clipboardSync, historyAccess, trustStore, fileStore, fileTransferState, cts.Token);
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
                : null,
            ownTailscaleAddress);
    }
}
