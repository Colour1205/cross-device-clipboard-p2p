# mobile/harmonyos/ — implementation plan (2026-09-18)

Target: HarmonyOS 7, API 26, ArkTS/ArkUI, built with DevEco Studio 26. This is
new ground for this project (and, honestly, for me too — API 26 is very
recent) so this plan leans conservative: prove the riskiest thing (protocol
compatibility with the Windows daemon) before building anything else.

## Hard constraint: wire compatibility with the Windows daemon

This app must speak the *exact same* protocol the Windows daemon already
implements — nothing here is a new design, it's a port. That means matching,
byte-for-byte where it matters:

- UDP discovery beacon: `"{tcpPort}:{deviceID}:{proof}:{address}"`, `-` for absent fields.
- TCP handshake: `HandshakeMessage { EphemeralPublicKey, IdentityPublicKey, Signature }` as one JSON line, ECDH on curve P-256 (nistP256/secp256r1), session key via `DeriveKeyFromHash` (SHA-256 over the shared secret).
- Session transport: every line after the handshake is `Convert.ToBase64String(nonce[12] + tag[16] + ciphertext)`, AES-256-GCM.
- Application messages: `Envelope { Type, Payload }` JSON, `Type` ∈ `entry | history_batch | file_chunk | file_request`.
- `ClipboardEntry { Content, Type, DeviceId, Timestamp, Signature }`, signed over `"{Content}:{Type}:{DeviceId}:{Timestamp:o}"` with ECDSA P-256 / SHA-256.
- Passphrase auto-trust: PBKDF2-SHA256, 210,000 iterations, **fixed salt** `"ClipboardDaemonPassphraseSaltV1"` (UTF-8 bytes) — this exact salt must match or two devices can never derive the same key from the same passphrase.
- File chunking: `FileChunkMessage { FileHash, ChunkIndex, IsLast, DataBase64 }`, `FilePayload { FileName, FileHash, FileSize }`, SHA-256 content-addressing.

Any mismatch in any of these (a different JSON casing, a different curve, a
different KDF parameter) means this app simply can't talk to anything else in
the mesh — it won't error cleanly, it'll just silently fail signature/AEAD
verification. That's why step 2 below is a dedicated compatibility spike
before any real app-building starts.

## Platform mapping (Windows piece → HarmonyOS API)

| Concern | Windows | HarmonyOS |
|---|---|---|
| Clipboard read/watch | `System.Windows.Forms.Clipboard` + polling | `@ohos.pasteboard`: `getSystemPasteboard()`, `on('update', cb)` for change notification. **No `changeCount`-equivalent exists** (confirmed via the pasteboard service source) — echo-suppression can only be content-hash-based here, same limitation already documented in `docs/architecture.md` for this exact platform. |
| Identity key (long-term ECDSA) | DPAPI-encrypted file | **HUKS** (Hardware Universal Keystore) — official guidance is explicit that long-term keys should live in HUKS, not be generated/exported via the crypto framework and serialized to a file. This is actually *better* than the Windows approach: the private key material can stay inside hardware-backed storage and never exist as exportable bytes at all. Needs a compatibility check: can HUKS export/sign in a way that produces standard P-256 signatures interoperable with .NET's `ECDsa`? — first thing to verify in the spike. |
| Passphrase/session crypto | `System.Security.Cryptography` | `@ohos.security.cryptoFramework` — confirmed support for AES-GCM (`createSymCipher('AES|GCM|PKCS7')`), HMAC, ECDH/ECDSA (ECC_256), PBKDF2. |
| Local persistence (history, trust store) | JSON files | `@ohos.data.preferences` for small config (trust store, passphrase-derived key reference), `@ohos.file.fs` for larger blobs (FileStore-equivalent). |
| Networking (UDP discovery, TCP peer link) | `System.Net.Sockets` | `@ohos.net.socket` — `constructUDPSocketInstance()` / `constructTCPSocketInstance()`. Requires `ohos.permission.INTERNET` declared in `module.json5`. |
| Background sync | N/A (always-on daemon) | **Foreground-only**, per the original architecture decision — HarmonyOS's background task model (Transient/Continuous/Deferred, none suited to "run indefinitely like a daemon") confirms that decision still holds for API 26. Sync happens on app open/foreground only. |

## Genuine unknowns — to resolve in the spike, not guess at

- **LAN broadcast/multicast permission specifics** weren't clearly confirmed in research — general `INTERNET` permission is documented, but nothing specific to broadcast/multicast beyond that surfaced. Needs hands-on verification; if HarmonyOS restricts this further than expected, discovery may need to fall back to Tailscale-address-only or manual QR pairing *specifically* on this platform (same kind of per-platform tradeoff already made for image/file sync support).
- **HUKS-signed output format compatibility** with .NET's ECDSA signature encoding (both should be raw P-256, but this needs an actual test, not an assumption).
- **PBKDF2 output compatibility** — needs a known-input/known-output test vector compared against the C# implementation before trusting it.

## Environment setup

1. **DevEco Studio 26** (Beta as of this writing) — download from the official Huawei developer site. Windows requirements: Windows 10/11 64-bit, **16GB+ RAM, 100GB+ free disk**, 1280×800+ display. The installer bundles the HarmonyOS SDK, Node.js, hvigor (build tool), ohpm (package manager), and an ARM-based emulator — no separate downloads needed for those.
2. **A Huawei Developer account** — needed to download the SDK/tooling and to deploy to a real device.
3. **Testing target**: the bundled emulator is fine for UI/clipboard basics, but given how much of this app is real networking behavior (UDP broadcast, TCP handshake, LAN discovery), **a real HarmonyOS device is strongly recommended** once past the initial spike — emulator networking often doesn't behave identically to a real device on a real LAN.

## Build order

1. ~~**Environment + hello-world**~~ — done (2026-09-17). DevEco Studio 26 installed, Empty Ability project created under `entry/`, blank ArkTS app confirmed running on a real device.
2. **Protocol compatibility spike** (before any real app structure) — in progress. `entry/src/main/ets/pages/Index.ets` currently holds the spike harness (not a real app screen yet — it replaces the default hello-world page temporarily), with two on-device tests:
   - **PBKDF2-SHA256**: derives a key from a fixed passphrase/salt using `cryptoFramework`, compares against a reference hex value computed via `dotnet run` on the actual .NET crypto APIs `PassphraseAuth.cs` uses. Pass/fail is exact-match, shown on screen.
   - **HUKS ECDSA P-256 signing**: generates a key via HUKS, signs a fixed string, and reports the raw signature length/bytes. The open question flagged below (raw r||s vs DER) gets answered here by inspection — 64 bytes = raw (matches .NET directly), other length starting with `0x30` = DER (needs a conversion step before it'll interop with `ECDsa.VerifyData`).

   Run it on the real device and report back the two on-screen results (or errors) — that determines whether HUKS can be used as-is for the identity key or needs a DER→raw signature adapter.
3. **Clipboard read + watch** — `@ohos.pasteboard`, content-hash-based echo suppression (no sequence-number equivalent here).
4. **Local persistence** — identity in HUKS, trust store + passphrase key reference in Preferences, file blobs in `@ohos.file.fs`.
5. **Networking** — UDP discovery (send/receive, matching the exact beacon format), then TCP connect.
6. **Handshake + session encryption** — the real interop test: this app connects to an *actual running Windows daemon instance*, completes the ECDH handshake, and both sides confirm they derived the same session key.
7. **Signing/verification + trust store integration.**
8. **Full sync**: send/receive `entry`/`history_batch` envelopes, apply to clipboard.
9. **Foreground-only lifecycle wiring** — sync triggers on app open/foreground, per the architecture doc; minimal UI (pairing screen, connected/trusted devices, maybe a history view).
10. **File transfer** (chunking, `FileStore`-equivalent) — deliberately last, since it's the most complex piece and everything before it needs to be solid first.
