# Security & trust model (draft)

## Pairing

Devices must be explicitly paired before they trust each other's clipboard data. Suggested flow:

1. Each device generates a long-term keypair on first run (identity).
2. Pairing exchanges public keys out-of-band (QR code shown on one device, scanned by the other; or a short numeric code typed on both) — this prevents an unpaired device on the same LAN from silently joining the mesh.
3. Paired device public keys are stored locally; only peers with a known/trusted key are accepted on the peer link.

## Transport security

- Presence beacons (`HELLO`) are unauthenticated by nature (broadcast) and must never contain clipboard content — only device id + metadata.
- The actual peer TCP link is encrypted and mutually authenticated using the paired keys (e.g. Noise protocol or TLS with pinned certs derived from the device keypair).

## Data at rest

- Local history store should be encrypted at rest (or at least access-restricted) since it accumulates sensitive clipboard content (passwords, tokens, etc. users may copy).
- Consider a "don't sync sensitive content" heuristic later (e.g. skip content that looks like a password-manager copy) — out of scope for v1.

## Threat model notes (draft, revisit before shipping)

- LAN-local attacker should not be able to join the mesh without completing pairing.
- A compromised/unpaired device should not be able to read or inject clipboard entries.
- Lost/stolen device: needs a way to revoke its trust from the others (unpair) — TBD.
