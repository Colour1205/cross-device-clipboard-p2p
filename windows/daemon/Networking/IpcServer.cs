using System.IO.Pipes;
using System.Text.Json;

namespace ClipboardDaemon.Networking;

// Local-machine-only IPC between this daemon and its tray app companion, over
// a named pipe (not a network socket — tray and daemon always run on the same
// PC). Same request-in, one-line-JSON, response-out shape as everything else
// in this project talks — just a different transport than PeerConnection.
public class IpcServer
{
    private readonly string pipeName;

    public IpcServer(string label)
    {
        pipeName = $"ClipboardDaemonIPC_{label}";
    }

    // The daemon (Program.cs) subscribes to this to actually answer requests.
    // Handler-per-request keeps IpcServer itself ignorant of what any command
    // means, same separation ClipboardSync/Discovery/PeerConnection already use.
    public event Func<IpcRequest, IpcResponse>? RequestReceived;

    public async Task Start()
    {
        while (true)
        {
            using var pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
            await pipe.WaitForConnectionAsync();
            await HandleClient(pipe);
        }
    }

    private async Task HandleClient(NamedPipeServerStream pipe)
    {
        try
        {
            using var reader = new StreamReader(pipe);
            using var writer = new StreamWriter(pipe) { AutoFlush = true };

            string? line = await reader.ReadLineAsync();
            if (line == null) return;

            var request = JsonSerializer.Deserialize<IpcRequest>(line);
            if (request == null) return;

            var response = RequestReceived?.Invoke(request) ?? new IpcResponse(false, "no handler registered");
            await writer.WriteLineAsync(JsonSerializer.Serialize(response));
        }
        catch (Exception)
        {
            // client disconnected unexpectedly — just move on to the next connection
        }
    }
}
