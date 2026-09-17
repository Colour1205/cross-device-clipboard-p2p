using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ClipboardDaemon.Identity;

namespace ClipboardDaemon.Networking;

public class PeerConnection
{
    private readonly TcpClient client;
    private readonly StreamReader reader;
    private readonly StreamWriter writer;
    private readonly byte[] sessionKey;

    // Known the moment the connection is created — verified during the
    // handshake, not inferred later from message content.
    public string PeerDeviceId { get; }

    public event Action<string>? MessageReceived;
    public event Action? Disconnected;

    private PeerConnection(TcpClient client, StreamReader reader, StreamWriter writer, byte[] sessionKey, string peerDeviceId)
    {
        this.client = client;
        this.reader = reader;
        this.writer = writer;
        this.sessionKey = sessionKey;
        PeerDeviceId = peerDeviceId;
    }

    // Performs the authenticated ECDH handshake described in HandshakeMessage.cs.
    // Returns null (never throws for a bad/untrusted peer) if the handshake
    // fails, the signature doesn't verify, or the peer isn't in our trust
    // store — callers should just close the socket and move on.
    public static async Task<PeerConnection?> CreateAsync(TcpClient client, DeviceIdentity myIdentity, TrustStore trustStore)
    {
        Stream stream = client.GetStream();
        var reader = new StreamReader(stream);
        var writer = new StreamWriter(stream) { AutoFlush = true };

        using var ecdh = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        byte[] myEphemeralPublicKey = ecdh.PublicKey.ExportSubjectPublicKeyInfo();
        byte[] mySignature = myIdentity.SignData(myEphemeralPublicKey);

        var myHandshake = new HandshakeMessage(
            Convert.ToBase64String(myEphemeralPublicKey),
            myIdentity.GetPublicKey(),
            Convert.ToBase64String(mySignature));
        await writer.WriteLineAsync(JsonSerializer.Serialize(myHandshake));

        string? theirHandshakeJson = await reader.ReadLineAsync();
        if (theirHandshakeJson == null) return null;

        HandshakeMessage? theirHandshake;
        try
        {
            theirHandshake = JsonSerializer.Deserialize<HandshakeMessage>(theirHandshakeJson);
        }
        catch (JsonException) { return null; }
        if (theirHandshake == null) return null;

        if (!trustStore.IsTrusted(theirHandshake.IdentityPublicKey))
        {
            return null; // not a device we trust — refuse the connection outright
        }

        byte[] theirEphemeralPublicKeyBytes;
        byte[] theirSignature;
        try
        {
            theirEphemeralPublicKeyBytes = Convert.FromBase64String(theirHandshake.EphemeralPublicKey);
            theirSignature = Convert.FromBase64String(theirHandshake.Signature);
        }
        catch (FormatException) { return null; }

        using var verifyEcdsa = ECDsa.Create();
        try
        {
            verifyEcdsa.ImportSubjectPublicKeyInfo(Convert.FromBase64String(theirHandshake.IdentityPublicKey), out _);
        }
        catch (CryptographicException) { return null; }

        if (!verifyEcdsa.VerifyData(theirEphemeralPublicKeyBytes, theirSignature, HashAlgorithmName.SHA256))
        {
            return null; // ephemeral key doesn't match the claimed identity's signature — tampered or spoofed
        }

        using var theirEcdh = ECDiffieHellman.Create();
        theirEcdh.ImportSubjectPublicKeyInfo(theirEphemeralPublicKeyBytes, out _);

        byte[] sessionKey = ecdh.DeriveKeyFromHash(theirEcdh.PublicKey, HashAlgorithmName.SHA256);

        return new PeerConnection(client, reader, writer, sessionKey, theirHandshake.IdentityPublicKey);
    }

    public async Task Send(string message)
    {
        await writer.WriteLineAsync(Encrypt(message));
    }

    public async Task Listen()
    {
        try
        {
            while (true)
            {
                string? line = await reader.ReadLineAsync();
                if (line == null) break; // peer closed cleanly
                MessageReceived?.Invoke(Decrypt(line));
            }
        }
        catch (Exception) { } // abrupt disconnect, or a corrupt/forged line that failed to decrypt
        finally
        {
            Disconnected?.Invoke();
        }
    }

    // Actively tears down the connection — used when a device gets untrusted
    // while still connected.
    public void Close()
    {
        client.Close();
    }

    private const int NonceSize = 12; // AES-GCM standard nonce size
    private const int TagSize = 16;

    private string Encrypt(string plaintext)
    {
        byte[] nonce = RandomNumberGenerator.GetBytes(NonceSize);
        byte[] plainBytes = Encoding.UTF8.GetBytes(plaintext);
        byte[] cipherBytes = new byte[plainBytes.Length];
        byte[] tag = new byte[TagSize];

        using var aesGcm = new AesGcm(sessionKey, TagSize);
        aesGcm.Encrypt(nonce, plainBytes, cipherBytes, tag);

        byte[] packed = new byte[NonceSize + TagSize + cipherBytes.Length];
        Buffer.BlockCopy(nonce, 0, packed, 0, NonceSize);
        Buffer.BlockCopy(tag, 0, packed, NonceSize, TagSize);
        Buffer.BlockCopy(cipherBytes, 0, packed, NonceSize + TagSize, cipherBytes.Length);
        return Convert.ToBase64String(packed);
    }

    private string Decrypt(string packedBase64)
    {
        byte[] packed = Convert.FromBase64String(packedBase64);
        byte[] nonce = packed[0..NonceSize];
        byte[] tag = packed[NonceSize..(NonceSize + TagSize)];
        byte[] cipherBytes = packed[(NonceSize + TagSize)..];
        byte[] plainBytes = new byte[cipherBytes.Length];

        using var aesGcm = new AesGcm(sessionKey, TagSize);
        aesGcm.Decrypt(nonce, cipherBytes, tag, plainBytes); // throws if tampered — caught in Listen()
        return Encoding.UTF8.GetString(plainBytes);
    }
}
