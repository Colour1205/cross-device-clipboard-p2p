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
    public async Task Start(string deviceID, int tcpPort)
    {
        UdpClient client = new UdpClient();
        client.EnableBroadcast = true;
        client.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        client.Client.Bind(new System.Net.IPEndPoint(IPAddress.Any, PORT));

        Task sendTask = Task.Run(async () =>
        {
            while (true)
            {
                await Send(client, $"{tcpPort}:{deviceID}");
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
                Console.WriteLine($"received: {message}"); //debug
                string[] parts = message.Split(':');
                int other_port = int.Parse(parts[0]);
                string other_device_id = parts[1];

                PeerDiscovered?.Invoke(other_device_id, sender, other_port);
            }
        });

        await Task.WhenAll(sendTask, receiveTask);
    }

    public event Action<string, IPAddress, int>? PeerDiscovered;

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
