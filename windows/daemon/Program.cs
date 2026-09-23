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
        // Guards against streaming the same file to the same peer twice at
        // once: ClipboardChanged proactively streams a freshly-captured
        // file right after broadcasting its entry, but the receiving side
        // (HandleIncomingFileEntry) also unconditionally broadcasts a
        // file_request the moment it sees an entry it doesn't have bytes
        // for yet, regardless of whether the sender is already streaming.
        // Without this guard that redundant request starts a SECOND
        // concurrent stream over the same connection, and the two chunk
        // sequences interleave on the wire - the actual cause of "file
        // transfer failed hash verification" on the receiving end.
        public ConcurrentDictionary<string, byte> StreamingInFlight = new();
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
                Console.WriteLine($"Received {entry.Type} message with invalid signature from peer (verified={SigningService.Verify(entry, entry.DeviceId)}, trusted={trustStore.IsTrusted(entry.DeviceId)}).");
                return;
            }
            Console.WriteLine($"[clip] received {entry.Type} entry from {entry.DeviceId[..Math.Min(12, entry.DeviceId.Length)]}... - applying");

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
            HandleFileRequest(envelope.Payload, fileStore, conn, fileTransferState);
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

    private static void HandleFileRequest(string payloadJson, FileStore fileStore, PeerConnection requestingConn, FileTransferState fileTransferState)
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
            Console.WriteLine($"[file] {requestingConn.PeerDeviceId[..Math.Min(12, requestingConn.PeerDeviceId.Length)]}... requested {request.FileHash[..12]}... - we have it, streaming");
            _ = StreamFileToPeer(requestingConn, fileStore.GetPath(request.FileHash), request.FileHash, fileTransferState);
        }
        else
        {
            Console.WriteLine($"[file] {requestingConn.PeerDeviceId[..Math.Min(12, requestingConn.PeerDeviceId.Length)]}... requested {request.FileHash[..12]}... - don't have it, ignoring");
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

        bool isNewTransfer = !fileTransferState.InProgressWrites.ContainsKey(chunk.FileHash);
        if (isNewTransfer)
        {
            Console.WriteLine($"[file] receiving {chunk.FileHash[..12]}...");
        }
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

        if (!string.Equals(actualHash, chunk.FileHash, StringComparison.OrdinalIgnoreCase))
        {
            // corrupted in transit, or tampered — the signed entry's hash is
            // what we trust, not whatever bytes actually showed up
            Console.WriteLine($"File transfer failed hash verification (expected {chunk.FileHash}, got {actualHash}) — discarding.");
            File.Delete(tempPath);
            fileTransferState.PendingEntries.TryRemove(chunk.FileHash, out _);
            return;
        }

        File.Move(tempPath, fileStore.GetPath(chunk.FileHash), overwrite: true);
        Console.WriteLine($"[file] received {chunk.FileHash[..12]}... - verified, saved");
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
    private static async Task StreamFileToPeer(PeerConnection conn, string filePath, string fileHash, FileTransferState fileTransferState)
    {
        string key = $"{conn.PeerDeviceId}:{fileHash}";
        if (!fileTransferState.StreamingInFlight.TryAdd(key, 0))
        {
            // Already streaming this exact file to this exact peer - see
            // StreamingInFlight's field comment.
            return;
        }
        const int chunkSize = 256 * 1024;
        string shortPeer = conn.PeerDeviceId[..Math.Min(12, conn.PeerDeviceId.Length)];
        Console.WriteLine($"[file] sending {fileHash[..12]}... to {shortPeer}...");
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
            Console.WriteLine($"[file] finished sending {fileHash[..12]}... to {shortPeer}... ({chunkIndex} chunks)");
        }
        catch (Exception ex)
        {
            // peer disconnected mid-transfer, or the source file became
            // unreadable — nothing further to do about it, but worth logging
            // since this used to fail completely silently
            Console.WriteLine($"[file] sending {fileHash[..12]}... to {shortPeer}... failed: {ex.Message}");
        }
        finally
        {
            fileTransferState.StreamingInFlight.TryRemove(key, out _);
        }
    }

    // Without this, a connection that's been idle for a while (this app
    // only sends when the clipboard actually changes, so idle is the common
    // case) can get silently dropped by an intermediate NAT or firewall
    // along the path - especially plausible over Tailscale/WireGuard, where
    // the "connection" is really just a NAT mapping that times out without
    // periodic traffic. TCP keepalive pings keep that mapping (and any
    // stateful firewall's idea of the connection) alive without needing
    // real application data to flow. Cross-platform since .NET 5 - not a
    // Windows-only trick despite this being the Windows daemon.
    private static void EnableKeepAlive(TcpClient client)
    {
        client.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
        client.Client.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveTime, 20);
        client.Client.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveInterval, 10);
        client.Client.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveRetryCount, 5);
    }

    private static void SendHistoryBatch(PeerConnection conn, HistoryAccess historyAccess)
    {
        var history = historyAccess.GetHistory();
        var envelope = new Envelope("history_batch", JsonSerializer.Serialize(history));
        var json = JsonSerializer.Serialize(envelope);
        _ = conn.Send(json);
    }

    // Wires up a connection for actual use - history sync, message
    // handling, disconnect cleanup. Shared by every path that ends up with
    // a live, already-trusted connection (reconnects, the TCP accept loop,
    // and accept_pairing once the user approves a candidate).
    private static void RegisterConnection(
        PeerConnection conn,
        ConcurrentDictionary<string, PeerConnection> connectionsByDeviceId,
        ClipboardSync clipboardSync,
        HistoryAccess historyAccess,
        TrustStore trustStore,
        FileStore fileStore,
        FileTransferState fileTransferState)
    {
        connectionsByDeviceId[conn.PeerDeviceId] = conn;
        Console.WriteLine($"[conn] connected: {conn.PeerDeviceId[..Math.Min(12, conn.PeerDeviceId.Length)]}... ({connectionsByDeviceId.Count} total)");
        SendHistoryBatch(conn, historyAccess);
        conn.MessageReceived += msg => HandleMessage(msg, conn, connectionsByDeviceId, clipboardSync, historyAccess, trustStore, fileStore, fileTransferState);
        conn.Disconnected += () =>
        {
            // Identity-checked removal, NOT TryRemove(key). When both ends
            // dial each other at once, the second connection replaces the
            // first in this map; removing by key alone meant the first
            // one's eventual teardown evicted the SECOND, live connection.
            // Both sides then believed they were disconnected and redialled,
            // which is the connect/disconnect flapping in the console and
            // why the clipboard stopped flowing - the map sat empty even
            // though a healthy socket existed. This overload only removes
            // the entry if it still points at this exact connection.
            bool removed = connectionsByDeviceId.TryRemove(
                new KeyValuePair<string, PeerConnection>(conn.PeerDeviceId, conn));
            if (removed)
            {
                Console.WriteLine($"[conn] disconnected: {conn.PeerDeviceId[..Math.Min(12, conn.PeerDeviceId.Length)]}... ({connectionsByDeviceId.Count} total)");
            }
            else
            {
                Console.WriteLine($"[conn] stale link closed for {conn.PeerDeviceId[..Math.Min(12, conn.PeerDeviceId.Length)]}...; live connection kept ({connectionsByDeviceId.Count} total)");
            }
        };
        _ = conn.Listen();
    }

    // Single funnel for every freshly-created PeerConnection, whichever of
    // the several places created it. An already-trusted peer is registered
    // immediately like always; one newly trusted via a matching passphrase
    // proof (NewlyTrustedViaPassphrase - see PeerConnection.CreateAsync) is
    // persisted to the trust store first, then registered the same way; a
    // genuine pairing candidate (only possible because PairingState.ModeOpen
    // was true) is parked as the pending candidate instead, for the tray's
    // accept_pairing/reject_pairing IPC commands to resolve. Never
    // auto-trusted just because a connection formed on its own.
    private static void HandleNewConnection(
        PeerConnection conn,
        string? address,
        PairingState pairingState,
        ConcurrentDictionary<string, PeerConnection> connectionsByDeviceId,
        ClipboardSync clipboardSync,
        HistoryAccess historyAccess,
        TrustStore trustStore,
        FileStore fileStore,
        FileTransferState fileTransferState)
    {
        if (conn.WasAlreadyTrusted)
        {
            if (conn.NewlyTrustedViaPassphrase)
            {
                Console.WriteLine($"Auto-pairing {conn.PeerDeviceId} — matching passphrase proof in handshake");
                trustStore.Trust(conn.PeerDeviceId, address);
            }
            else if (address != null)
            {
                // Already trusted, but now we know a real address for this
                // peer (e.g. captured off an incoming connection whose
                // remote endpoint we just read, or a fresh dial) - back-fill
                // it. Trust() upserts the address on an existing entry, so
                // this is what actually fixes a trust record that was
                // written back when the accept loop didn't capture an
                // address at all (an old bug - it always passed null),
                // instead of leaving it permanently stuck with no address
                // to reconnect off-LAN with.
                trustStore.Trust(conn.PeerDeviceId, address);
            }
            RegisterConnection(conn, connectionsByDeviceId, clipboardSync, historyAccess, trustStore, fileStore, fileTransferState);
            return;
        }
        if (!pairingState.TrySetPending(conn, address))
        {
            conn.Close(); // already have a candidate awaiting a decision
        }
    }

    // Dials out to a peer at a known address and wires it up exactly the same
    // way regardless of how that address was found — LAN discovery or a
    // cached off-LAN (Tailscale) address from the trust store. Only ever
    // used for peers we already expect to be trusted (the id we dial is
    // exactly the id we require back) - PairByAddress below is the
    // counterpart for a genuinely new, not-yet-identified pairing target.
    private static async Task ConnectToPeer(
        string peerDeviceId,
        string address,
        int port,
        DeviceIdentity myIdentity,
        PairingState pairingState,
        PassphraseKeyStore passphraseKeyStore,
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
        EnableKeepAlive(client);

        var conn = await PeerConnection.CreateAsync(client, myIdentity, trustStore, pairingState.ModeOpen, passphraseKeyStore);
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

        HandleNewConnection(conn, address, pairingState, connectionsByDeviceId, clipboardSync, historyAccess, trustStore, fileStore, fileTransferState);
    }

    // Counterpart to ConnectToPeer for a genuinely new pairing target - the
    // peer's identity isn't known in advance (that's what the handshake is
    // for), so there's no id to validate against. Used by the "pair_by_address"
    // IPC command and by the beacon handler's untrusted-pairing-candidate path.
    // Returns whether a connection was actually established (not whether
    // pairing succeeded - a candidate still counts as "connected", the
    // accept/reject decision happens separately via HandleNewConnection).
    private static async Task<bool> PairByAddress(
        string address,
        int port,
        DeviceIdentity myIdentity,
        PairingState pairingState,
        PassphraseKeyStore passphraseKeyStore,
        ConcurrentDictionary<string, PeerConnection> connectionsByDeviceId,
        ClipboardSync clipboardSync,
        HistoryAccess historyAccess,
        TrustStore trustStore,
        FileStore fileStore,
        FileTransferState fileTransferState)
    {
        try
        {
            TcpClient client = new TcpClient();
            await client.ConnectAsync(address, port);
            EnableKeepAlive(client);
            var conn = await PeerConnection.CreateAsync(client, myIdentity, trustStore, pairingState.ModeOpen, passphraseKeyStore);
            if (conn == null)
            {
                client.Close();
                return false;
            }
            HandleNewConnection(conn, address, pairingState, connectionsByDeviceId, clipboardSync, historyAccess, trustStore, fileStore, fileTransferState);
            return true;
        }
        catch (Exception)
        {
            return false; // not reachable right now
        }
    }
    [STAThread]
    static async Task Main(String[] args)
    {
        string label = args.Length > 0 ? args[0] : "default";
        string port = args.Length > 1 ? args[1] : "49000";
        string? trustedKeyToAdd = args.Length > 2 ? args[2] : null;

        var identity = new DeviceIdentity(label);
        var fileStore = new FileStore(label);
        var historyAccess = new HistoryAccess(label, fileStore);
        TrustStore trustStore = new TrustStore(label);
        var passphraseKeyStore = new PassphraseKeyStore(label);
        var fileTransferState = new FileTransferState();
        var pairingState = new PairingState();
        // Constructed here (rather than down by clipboardSync.ClipboardChanged's
        // registration, where it conceptually belongs) purely so the IPC handler
        // block below - which needs it for accept_pairing/pair_by_address - can
        // reference it; C# requires a local's declaration to textually precede
        // any lambda that captures it, even though this one won't run until later.
        var clipboardSync = new ClipboardSync(fileStore);
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
            else if (request.Command == "set_pairing_mode" && request.Payload != null)
            {
                // Driven by the tray's Pairing dialog opening/closing - mirrors
                // HarmonyOS's Index.ets pairingOpen. Only while this is true does
                // PeerConnection.CreateAsync accept a handshake from an untrusted
                // peer at all (see its own doc comment).
                pairingState.ModeOpen = request.Payload == "1";
                return new IpcResponse(true, pairingState.ModeOpen.ToString());
            }
            else if (request.Command == "get_pending_pairing")
            {
                // Polled by the tray while its Pairing dialog is open - there's no
                // push channel from daemon to tray over this IPC transport, so the
                // dialog just asks every second or so. Empty string means nothing
                // pending.
                return new IpcResponse(true, pairingState.PendingPeerId ?? "");
            }
            else if (request.Command == "accept_pairing")
            {
                var taken = pairingState.TakePending();
                if (taken == null)
                {
                    return new IpcResponse(false, "nothing pending");
                }
                trustStore.Trust(taken.Value.conn.PeerDeviceId, taken.Value.address);
                RegisterConnection(taken.Value.conn, connectionsByDeviceId, clipboardSync, historyAccess, trustStore, fileStore, fileTransferState);
                return new IpcResponse(true, "paired");
            }
            else if (request.Command == "reject_pairing")
            {
                pairingState.RejectPending();
                return new IpcResponse(true, "rejected");
            }
            else if (request.Command == "pair_by_address" && request.Payload != null)
            {
                // Windows has no camera to scan a QR with, so this is the
                // primary way to pair from here - type/paste an address (or the
                // full {PublicKey,Address} pairing JSON copied from the other
                // device; only Address is actually used, since the peer's real
                // identity comes from the signature-verified handshake, not
                // from anything typed here). Fire-and-forget: the tray polls
                // get_pending_pairing for the result rather than blocking this
                // IPC round-trip on a network connect attempt.
                string address = request.Payload;
                try
                {
                    var parsed = JsonSerializer.Deserialize<PairingInfo>(request.Payload);
                    if (parsed != null && !string.IsNullOrWhiteSpace(parsed.Address))
                    {
                        address = parsed.Address;
                    }
                }
                catch (JsonException) { /* not JSON - treat the raw input as a bare address */ }
                _ = PairByAddress(address, int.Parse(port), identity, pairingState, passphraseKeyStore, connectionsByDeviceId, clipboardSync, historyAccess, trustStore, fileStore, fileTransferState);
                return new IpcResponse(true, "connecting");
            }
            else
            {
                return new IpcResponse(false, "unknown command");
            }
        };
        _ = Task.Run(() => ipcServer.Start());

        // clipboard watcher
        clipboardSync.ClipboardChanged += content =>
        {
            Console.WriteLine($"[clip] detected local {content.type} change ({content.content.Length} chars/bytes-base64) - {connectionsByDeviceId.Count} peer(s) connected");
            var entry = new ClipboardEntry(content.content, content.type, identity.GetPublicKey(), DateTime.UtcNow);
            var signedEntry = SigningService.Sign(entry, identity);
            var envelope = new Envelope("entry", JsonSerializer.Serialize(signedEntry));
            var json = JsonSerializer.Serialize(envelope);
            foreach (var conn in connectionsByDeviceId.Values)
            {
                string peerShort = conn.PeerDeviceId[..Math.Min(12, conn.PeerDeviceId.Length)];
                _ = conn.Send(json).ContinueWith(t =>
                {
                    if (t.IsFaulted)
                    {
                        Console.WriteLine($"[clip] failed sending {content.type} entry to {peerShort}...: {t.Exception?.GetBaseException().Message}");
                    }
                }, TaskContinuationOptions.OnlyOnFaulted);
            }
            historyAccess.addToHistory(signedEntry);

            if (content.type == "file" && content.sourceFilePath != null)
            {
                FilePayload? payload = null;
                try { payload = JsonSerializer.Deserialize<FilePayload>(content.content); }
                catch (JsonException) { }

                if (payload != null)
                {
                    Console.WriteLine($"[file] copied: {payload.FileName} ({payload.FileSize} bytes, {payload.FileHash[..12]}...) - {connectionsByDeviceId.Count} peer(s) connected");
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
                            _ = StreamFileToPeer(conn, fileStore.GetPath(payload.FileHash), payload.FileHash, fileTransferState);
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
                EnableKeepAlive(client);
                // Without capturing this, a device that only ever DIALED OUT
                // to pair (rather than being dialed) would never learn an
                // address for whoever just connected to it - meaning it could
                // never later reconnect off-LAN on its own (see the off-LAN
                // reconnect loop below), only ever be reconnected TO.
                string? remoteAddress = (client.Client.RemoteEndPoint as IPEndPoint)?.Address.ToString();

                var conn = await PeerConnection.CreateAsync(client, identity, trustStore, pairingState.ModeOpen, passphraseKeyStore);
                if (conn == null)
                {
                    // handshake failed, or whoever connected isn't in our trust
                    // store and we're not expecting to pair right now — refuse at
                    // the connection level, not just per-message
                    client.Close();
                    continue;
                }

                HandleNewConnection(conn, remoteAddress, pairingState, connectionsByDeviceId, clipboardSync, historyAccess, trustStore, fileStore, fileTransferState);
            }

        });




        Discovery discovery = new Discovery();

        discovery.PeerDiscovered += async (other_device_id, sender, other_port, proof, peerAddress, otherPairingOpen) =>
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

            bool isTrusted = trustStore.IsTrusted(other_device_id);

            // connect only when the other device's public key is "smaller" than this device's public key (to avoid duplicate connections)
            // connect only if the other device is in the trust store
            if (!connectionsByDeviceId.ContainsKey(other_device_id) && other_device_id.CompareTo(identity.GetPublicKey()) < 0
            && isTrusted)
            {
                Console.WriteLine($"Discovered peer {other_device_id} at {other_port}");
                try
                {
                    await ConnectToPeer(other_device_id, sender.ToString(), other_port, identity, pairingState, passphraseKeyStore, connectionsByDeviceId, clipboardSync, historyAccess, trustStore, fileStore, fileTransferState);
                }
                catch (Exception)
                {
                    // peer wasn't actually reachable — ignore, we'll hear its next beacon
                }
            }
            // Sibling path for UNTRUSTED peers - only attempts a handshake at
            // all when BOTH this device's own pairing mode is open
            // (pairingState.ModeOpen) AND the beacon says the sender's is too
            // (otherPairingOpen) - two independent, live, local "I'm expecting
            // to pair right now" signals, not just one side's assumption. Same
            // tie-breaker as above so both sides don't dial each other
            // simultaneously; the handshake that results is what actually
            // surfaces the accept/reject prompt (see HandleNewConnection).
            else if (pairingState.ModeOpen && otherPairingOpen && !isTrusted
                && !connectionsByDeviceId.ContainsKey(other_device_id) && other_device_id.CompareTo(identity.GetPublicKey()) < 0
                && pairingState.PendingPeerId == null)
            {
                Console.WriteLine($"Discovered pairing candidate {other_device_id} at {other_port}");
                await PairByAddress(sender.ToString(), other_port, identity, pairingState, passphraseKeyStore, connectionsByDeviceId, clipboardSync, historyAccess, trustStore, fileStore, fileTransferState);
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
                            await ConnectToPeer(device.PublicKey, device.Address!, int.Parse(port), identity, pairingState, passphraseKeyStore, connectionsByDeviceId, clipboardSync, historyAccess, trustStore, fileStore, fileTransferState, cts.Token);
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
            ownTailscaleAddress,
            () => pairingState.ModeOpen);
    }
}
