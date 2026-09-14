# Protocol (draft)

Concrete message shapes live in `protocol/schema/`. This doc covers behavior.

## Transport

- **Discovery**: UDP broadcast on the LAN subnet, periodic "hello" beacon containing device ID + a short capability/version string. mDNS/Bonjour-style service advertisement is an acceptable alternative/addition.
- **Peer link**: once two nodes discover each other, they open a direct TCP connection secured with the pairing-derived key (see `docs/security.md`). All clipboard data and history sync happens over this link — the broadcast channel only ever carries presence beacons, never clipboard content.

## Message types

- `HELLO` — presence beacon (broadcast, unencrypted metadata only: device id, display name, protocol version).
- `CLIP_PUSH` — "here is a new clipboard entry" (sent to all currently-connected peers when the local clipboard changes).
- `HISTORY_REQUEST` — "send me everything you have after vector-clock/timestamp X".
- `HISTORY_RESPONSE` — batch of clipboard entries answering a `HISTORY_REQUEST`.
- `ACK` — optional delivery acknowledgement, used to prune what still needs to be gossiped further.

## Clipboard entry (conceptual shape)

```
id            : ulid/uuid, globally unique, generated at capture time
device_id     : id of the device that captured it
created_at    : capture timestamp (UTC)
content_type  : text | image | file-ref | ...
content       : raw bytes or reference (large payloads may be chunked/streamed separately)
content_hash  : dedupe key
```

## Reconciliation

Each node keeps a per-peer "last known state" (a logical clock or last-seen entry id per device). On connect:

1. Both sides exchange their per-device high-water marks.
2. Each side sends `HISTORY_REQUEST` for anything the other has that it doesn't.
3. New local clipboard changes are pushed live via `CLIP_PUSH` to whoever is currently connected, and picked up by everyone else next time they reconcile with any node that has it — this is what makes offline devices eventually consistent without a central server.

## Open questions / future work

- Off-LAN relay/NAT traversal for syncing when devices aren't on the same network.
- Large payloads (images, files) — chunking and backpressure.
- Conflict handling when two devices copy near-simultaneously (currently: both entries are kept, ordered by timestamp, no "winner").
