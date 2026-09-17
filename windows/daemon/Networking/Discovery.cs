// STEP 5:
// UDP broadcast discovery. Send a periodic "HELLO" beacon (device id + name)
// to the LAN, and listen for beacons from other devices.
//
// We'll test this by running two instances of the daemon on this same PC
// (different ports) and watching them find each other.

using System.Net;
using System.Net.Sockets;

namespace ClipboardDaemon.Networking;

public class Discovery
{
    // TODO
    public int PORT = 52388;

    // getProof is called fresh on every beacon, not just once at startup — a
    // passphrase set later via the tray (the normal flow: daemon starts first,
    // then the user sets a passcode) must take effect without a restart.
    // Result lets a peer that knows the same passphrase auto-trust this device
    // without any manual QR/key exchange — see Crypto/PassphraseAuth.cs.
    // "-" means "no passphrase configured", since the beacon is plain-text UDP.
    //
    // ownAddress is this device's off-LAN (Tailscale) address, if any — carried
    // so passphrase auto-trust can cache it too, same as QR/manual pairing does,
    // so passphrase-paired devices still get found later when off-LAN.
    public async Task Start(string deviceID, int tcpPort, Func<string?>? getProof = null, string? ownAddress = null)
    {
        UdpClient client = new UdpClient();
        client.EnableBroadcast = true;
        client.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        client.Client.Bind(new System.Net.IPEndPoint(IPAddress.Any, PORT));

        Task sendTask = Task.Run(async () =>
        {
            while (true)
            {
                string? proof = getProof?.Invoke();
                await Send(client, $"{tcpPort}:{deviceID}:{proof ?? "-"}:{ownAddress ?? "-"}");
                await Task.Delay(2000);
            }
        });

        Task receiveTask = Task.Run(async () =>
        {
            while (true)
            {
                var result = await Receive(client);
                string message = result.message;
                IPAddress sender = result.sender;
                string[] parts = message.Split(':');
                if (parts.Length < 3) continue; // malformed/old-format beacon, ignore

                int other_port = int.Parse(parts[0]);
                string other_device_id = parts[1];
                string? receivedProof = parts[2] == "-" ? null : parts[2];
                string? receivedAddress = parts.Length > 3 && parts[3] != "-" ? parts[3] : null;

                PeerDiscovered?.Invoke(other_device_id, sender, other_port, receivedProof, receivedAddress);
            }
        });

        await Task.WhenAll(sendTask, receiveTask);
    }

    public event Action<string, IPAddress, int, string?, string?>? PeerDiscovered;

    private async Task Send(UdpClient client, string message)
    {
        byte[] data = strToByte(message);
        await client.SendAsync(data, data.Length, new IPEndPoint(IPAddress.Broadcast, PORT));
    }

    private async Task<(string message, IPAddress sender)> Receive(UdpClient client)
    {
        while (true)
        {
            var result = await client.ReceiveAsync();
            string message = byteToStr(result.Buffer);
            return (message, result.RemoteEndPoint.Address);
        }
    }

    private byte[] strToByte(string str)
    {
        return System.Text.Encoding.UTF8.GetBytes(str);
    }
    private string byteToStr(byte[] bytes)
    {
        return System.Text.Encoding.UTF8.GetString(bytes);
    }
}
