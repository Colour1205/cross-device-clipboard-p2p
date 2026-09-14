# windows/

Windows implementation: a background daemon (the always-on P2P node) plus a tray app for status/pairing/history UI.

- `daemon/` — the actual P2P node: discovery, peer connections, clipboard watcher, history store, sync engine. Runs continuously (Windows service or startup-launched background process).
- `tray/` — tray icon UI: shows connection/peer status, lets the user browse clipboard history, and drives the pairing flow. Talks to `daemon/` over a local IPC channel (named pipe / localhost socket) rather than duplicating any networking logic.
- `shared/` — models/DTOs shared between `daemon/` and `tray/` (and generated from `protocol/schema/` for anything that crosses the network).

Proposed stack: .NET 8 (C#) — solid Win32 clipboard-hook support (`AddClipboardFormatListener`), easy sockets, easy to ship a tray app with a background worker service. Open to revisiting if you'd rather use something else (Rust, Go, etc.) — nothing below depends on the choice yet.
