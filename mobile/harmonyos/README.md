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
| Clipboard read/watch | `System.Windows.Forms.Clipboard` + polling | `@ohos.pasteboard`: `getSystemPasteboard()`, `on('update', cb)` for change notification (free, no permission). **Reading content is restricted** — `ohos.permission.READ_PASTEBOARD` is above normal APL; declaring it in `module.json5` made the app fail to *install* on-device (`hdc shell bm install`: "grant request permissions failed"), not just fail at runtime. Actual content reads must go through a tap-triggered `PasteButton` security component, which needs no permission declaration at all but only grants a **temporary** read window for that gesture. Net effect: no silent auto-pull is possible for a normal app — see step 3 below. **No `changeCount`-equivalent exists** either (confirmed via the pasteboard service source) — echo-suppression is content-hash-based, same limitation already documented in `docs/architecture.md` for this exact platform. |
| Identity key (long-term ECDSA) | DPAPI-encrypted file | **HUKS** (Hardware Universal Keystore) — official guidance is explicit that long-term keys should live in HUKS, not be generated/exported via the crypto framework and serialized to a file. This is actually *better* than the Windows approach: the private key material can stay inside hardware-backed storage and never exist as exportable bytes at all. Needs a compatibility check: can HUKS export/sign in a way that produces standard P-256 signatures interoperable with .NET's `ECDsa`? — first thing to verify in the spike. |
| Passphrase/session crypto | `System.Security.Cryptography` | `@ohos.security.cryptoFramework` — confirmed support for AES-GCM (`createSymCipher('AES|GCM|PKCS7')`), HMAC, ECDH/ECDSA (ECC_256), PBKDF2. |
| Local persistence (history, trust store) | JSON files | `@ohos.data.preferences` for small config (trust store, passphrase-derived key reference), `@ohos.file.fs` for larger blobs (FileStore-equivalent). |
| Networking (UDP discovery, TCP peer link) | `System.Net.Sockets` | `@ohos.net.socket` — `constructUDPSocketInstance()` / `constructTCPSocketInstance()`. Requires `ohos.permission.INTERNET` declared in `module.json5`. |
| Background sync | N/A (always-on daemon) | **Foreground-only**, per the original architecture decision — HarmonyOS's background task model (Transient/Continuous/Deferred, none suited to "run indefinitely like a daemon") confirms that decision still holds for API 26. Sync happens on app open/foreground only. |

## Genuine unknowns — resolved via the spike (2026-09-18/19)

- ~~**HUKS-signed output format compatibility**~~ — RESOLVED: **DER/ASN.1-encoded** (measured 70/71/72 bytes across runs, always starting `0x30` — the small length variance is normal DER, depending on whether `r`/`s` need a leading zero byte). **Not** raw r‖s like .NET's `ECDsa.SignData`/`VerifyData` default. A DER↔raw conversion step is required wherever a HUKS-produced signature needs to interop with the Windows daemon (or vice versa) — needs implementing before step 7 (signing/verification).
- ~~**PBKDF2 output compatibility**~~ — RESOLVED, but not the way expected: `cryptoFramework.createKdf('PBKDF2|SHA256').generateSecret()` **fails on-device** with `code 401, message: "build context fail"`, reproducibly, regardless of iteration count (tried 210,000 and 1), `algName` literal (`'PBKDF2Spec'` and `'Pbkdf2ParamsSpec'`), or `password` type (`Uint8Array` and `string`). Device confirmed at `OpenHarmony-7.0.0.105`, `sdkApiVersion 26` — exactly matches the SDK, so it's not a version mismatch. `cryptoFramework`'s HMAC-SHA256 path was verified working and byte-exact against .NET's `HMACSHA256` in isolation, which narrows this to a genuine gap in this Beta OS build's native PBKDF2 implementation specifically, not a parameter-shape bug or a broader crypto framework problem.
  **Workaround (implemented and verified correct)**: PBKDF2-HMAC-SHA256 built manually on top of the working HMAC primitive (standard construction: `T_i = U_1 xor U_2 xor ... xor U_c`, `U_1 = HMAC(P, S‖INT32BE(i))`, `U_j = HMAC(P, U_{j-1})`). Verified byte-exact against a .NET reference at both 1,000 and 210,000 iterations. This is what the real app should use for the identity/passphrase KDF — not the built-in `Kdf.generateSecret`. Worth re-testing the built-in path against a future OS update in case it gets fixed, but don't block on it.
- **LAN broadcast/multicast permission specifics** — still unverified, deferred to step 5 (networking) since it needs actual socket code to test, not just crypto.

## Environment setup

1. **DevEco Studio 26** (Beta as of this writing) — download from the official Huawei developer site. Windows requirements: Windows 10/11 64-bit, **16GB+ RAM, 100GB+ free disk**, 1280×800+ display. The installer bundles the HarmonyOS SDK, Node.js, hvigor (build tool), ohpm (package manager), and an ARM-based emulator — no separate downloads needed for those.
2. **A Huawei Developer account** — needed to download the SDK/tooling and to deploy to a real device.
3. **Testing target**: the bundled emulator is fine for UI/clipboard basics, but given how much of this app is real networking behavior (UDP broadcast, TCP handshake, LAN discovery), **a real HarmonyOS device is strongly recommended** once past the initial spike — emulator networking often doesn't behave identically to a real device on a real LAN.

## Build order

1. ~~**Environment + hello-world**~~ — done (2026-09-17). DevEco Studio 26 installed, Empty Ability project created under `entry/`, blank ArkTS app confirmed running on a real device.
2. ~~**Protocol compatibility spike**~~ — done (2026-09-19). `entry/src/main/ets/pages/Index.ets` holds the spike harness (still not a real app screen — replaces the default hello-world page temporarily; will be replaced for real in step 3). Four on-device tests, all resolved — see "Genuine unknowns" above for the detailed findings:
   1. **PBKDF2-SHA256 via built-in `Kdf`** — fails on-device (platform bug, not our bug).
   2. **HUKS ECDSA P-256 signing** — works, but DER-encoded, not raw r‖s.
   3. **HMAC-SHA256 baseline** — works, byte-exact vs .NET.
   4. **Manual PBKDF2-via-HMAC workaround** — works, byte-exact vs .NET at both 1,000 and 210,000 iterations.

   Carry forward into later steps: `pbkdf2Sha256Manual()` (test 4) for the real passphrase-derived key in step 4, and a DER↔raw signature converter (needed before step 7) for HUKS-signed data to interop with `ECDsa`.
3. ~~**Clipboard read + watch**~~ — working (2026-09-19) via the tap-to-sync model: `entry/src/main/ets/clipboard/ClipboardWatcher.ets` + `pages/Index.ets`. Confirmed on-device that declaring `ohos.permission.READ_PASTEBOARD` blocks the app from installing at all (see platform mapping table above); pivoted to the `PasteButton` security component, which needs no permission declaration and grants a temporary read window on tap. `pasteboard.on('update')` (free) flips a "pending change" indicator; the user taps `PasteButton` to actually read + hash + record content.

   **Pursuing true auto-read via ACL, in parallel, not blocking further work**: `READ_PASTEBOARD` can be unlocked via Huawei's ACL process — email `agconnect@huawei.com` with the app's AGC APP ID + permission name + use-case description (~1 business day turnaround), then generate a debug Profile with that permission checked and this device's UDID registered, then switch DevEco Studio's signing from automatic to manual/custom (Project Structure → Signing Configs) using the resulting cert files. This is an account/email process only the project owner can do — not something automatable here. Once the Profile is in hand: re-add `READ_PASTEBOARD` to `module.json5`, and change `ClipboardWatcher`'s `on('update')` handler to call `readCurrentClipboard()` directly instead of requiring a `PasteButton` tap.

   Until then, the tap-to-sync model is the real, permanent fallback (not just a placeholder) — worth keeping even after ACL is granted, in case the ACL request is ever denied or a future OS update changes the rules. Reflect this in the step 9 UI design (a persistent "sync now" affordance in addition to any auto-read) and in `docs/architecture.md`'s per-platform notes.
4. **Local persistence** — identity in HUKS, trust store + passphrase key reference in Preferences, file blobs in `@ohos.file.fs`.
5. **Networking** — UDP discovery (send/receive, matching the exact beacon format), then TCP connect.
6. **Handshake + session encryption** — the real interop test: this app connects to an *actual running Windows daemon instance*, completes the ECDH handshake, and both sides confirm they derived the same session key.
7. **Signing/verification + trust store integration.**
8. **Full sync**: send/receive `entry`/`history_batch` envelopes, apply to clipboard.
9. **Foreground-only lifecycle wiring** — sync triggers on app open/foreground, per the architecture doc; minimal UI (pairing screen, connected/trusted devices, maybe a history view).
10. **File transfer** (chunking, `FileStore`-equivalent) — deliberately last, since it's the most complex piece and everything before it needs to be solid first.
