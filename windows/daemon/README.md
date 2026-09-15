# windows/daemon/

Build order (each step should run/work before moving to the next):

1. `Program.cs` — hello-world console app, confirm `dotnet run` works.
2. `Clipboard/ClipboardSync.cs` — read/watch/set the Windows clipboard.
3. `Identity/DeviceIdentity.cs` — generate/load this device's keypair.
4. `Networking/Discovery.cs` — UDP broadcast presence + listen for peers.
5. `Networking/PeerConnection.cs` — TCP link to a discovered peer.
6. `Crypto/SigningService.cs` — sign outgoing entries, verify incoming ones.
7. `Storage/HistoryStore.cs` — persist clipboard history to disk.

Then wire these together in `Program.cs` into the actual daemon loop.
