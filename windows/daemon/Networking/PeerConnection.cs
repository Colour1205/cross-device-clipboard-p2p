// STEP 6:
// Turn a discovered peer into an actual TCP connection, and send/receive
// simple messages over it. Encryption/mutual-auth comes after the basic
// plumbing works.

using System.Net.Sockets;

namespace ClipboardDaemon.Networking;

public class PeerConnection
{
    private readonly StreamReader reader;
    private readonly StreamWriter writer;
    // TODO
    public PeerConnection(TcpClient client)
    {
        Stream stream = client.GetStream();
        reader = new StreamReader(stream);
        writer = new StreamWriter(stream) { AutoFlush = true };
    }
    public event Action<string>? MessageReceived;
    public async Task Send(string message)
    {
        await writer.WriteLineAsync(message);
    }
    public async Task Listen()
    {
        while (true)
        {
            string? line = await reader.ReadLineAsync();
            if (line == null) break; // peer disconnected
            MessageReceived?.Invoke(line);
        }
        
    }


}
