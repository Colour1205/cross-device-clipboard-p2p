namespace ClipboardDaemon.Networking;

// Request/response shape for local IPC between the daemon and its tray app
// companion, over a named pipe. Same one-JSON-line-per-message idea as the
// peer-to-peer Envelope, just for a different (local-only) channel.
public record IpcRequest(string Command, string? Payload = null);
public record IpcResponse(bool Success, string? Data = null);

// What "get_pairing_info" returns and "trust_device" accepts — a device's
// public key plus its optional off-LAN (Tailscale) address, bundled together
// so pairing captures both in one exchange (QR code, or pasted text).
public record PairingInfo(string PublicKey, string? Address = null);
