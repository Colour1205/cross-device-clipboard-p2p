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
    public async Task Start(string deviceID)
    {
        UdpClient client = new UdpClient();
        client.EnableBroadcast = true;
        client.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        client.Client.Bind(new System.Net.IPEndPoint(IPAddress.Any, PORT));

        Task sendTask = Task.Run(async () =>
        {
            while (true)
            {
                await Send(client, $"HELLO {deviceID}");
                await Task.Delay(2000);
            }
        });

        Task receiveTask = Task.Run(async () =>
        {
            while (true)
            {
                string message = await Receive(client);
                Console.WriteLine($"received: {message}");
            }
        });

        await Task.WhenAll(sendTask, receiveTask);
    }

    private async Task Send(UdpClient client, string message)
    {
        byte[] data = strToByte(message);
        await client.SendAsync(data, data.Length, new IPEndPoint(IPAddress.Broadcast, PORT));
    }

    private async Task<string> Receive(UdpClient client)
    {
        while (true)
        {
            var result = await client.ReceiveAsync();
            string message = byteToStr(result.Buffer);
            return message;
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
