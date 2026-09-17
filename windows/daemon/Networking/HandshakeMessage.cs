namespace ClipboardDaemon.Networking;

// The first (and only unencrypted) thing exchanged on every connection.
// EphemeralPublicKey sets up session encryption via ECDH — fresh per
// connection, so a leaked long-term key can't decrypt past sessions
// (forward secrecy). IdentityPublicKey + Signature (over EphemeralPublicKey)
// prove which device this really is: plain ECDH alone is vulnerable to a
// man-in-the-middle who swaps in their own ephemeral key, but they can't
// produce a valid signature without the real device's private key.
public record HandshakeMessage(string EphemeralPublicKey, string IdentityPublicKey, string Signature);
