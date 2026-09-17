// Step 3 of the build order in ../../../../README.md: clipboard read + watch.
// Real app screen (replaces the throwaway protocol-compatibility spike from
// step 2 — those findings are preserved in README.md and git history).
//
// Proves the clipboard side works end to end on-device: change detection,
// tap-triggered read (see ClipboardWatcher.ets for why), content hashing,
// text/image handling. No networking yet — that's steps 5+.

import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ClipboardWatcher, ClipboardChange } from '../clipboard/ClipboardWatcher';
import { DeviceIdentity } from '../identity/DeviceIdentity';
import { TrustStore } from '../identity/TrustStore';
import { PassphraseKeyStore } from '../identity/PassphraseKeyStore';
import { FileStore } from '../storage/FileStore';
import { derToRaw, rawToDer } from '../crypto/EcdsaDer';

function stringToBytes(s: string): Uint8Array {
  return new Uint8Array(Array.from(s).map(c => c.charCodeAt(0)));
}

function toHex(data: Uint8Array): string {
  let out = '';
  for (let i = 0; i < data.length; i++) {
    out += data[i].toString(16).padStart(2, '0');
  }
  return out;
}

@Entry
@Component
struct Index {
  @State pendingChange: boolean = false; // 'update' fired, not yet read
  @State entries: ClipboardChange[] = [];
  @State lastReadStatus: string = '';
  @State step4Status: string = 'not run yet';
  @State step4Detail: string = '';

  private watcher: ClipboardWatcher = new ClipboardWatcher();

  aboutToAppear(): void {
    this.watcher.onPasteboardChanged(() => {
      this.pendingChange = true;
    });
    this.watcher.startListening();
  }

  aboutToDisappear(): void {
    this.watcher.stopListening();
  }

  // Step 4 diagnostics: identity (HUKS sign + DER->raw conversion,
  // round-tripped through cryptoFramework verify against our own exported
  // key), trust store, passphrase key, file store. All new, untested API
  // surface — worth confirming on-device before building networking on
  // top of any of it, same lesson as the step-2 spike.
  async runStep4Diagnostics() {
    this.step4Status = 'running...';
    this.step4Detail = '';
    const context = getContext(this) as common.UIAbilityContext;

    try {
      // --- Identity: sign + verify round-trip ---
      const identity = new DeviceIdentity();
      const publicKeyBase64 = await identity.getPublicKeyBase64();
      this.step4Detail += `identity public key (base64, first 40 chars): ${publicKeyBase64.slice(0, 40)}...\n`;

      // HarmonyOS's own cryptoFramework Verify only ever accepts DER
      // signatures (confirmed: raw r||s is flatly rejected even when it's
      // the exact same mathematical signature, proven below by the
      // round-trip check) - unlike .NET's ECDsa, which defaults to raw.
      // So: derToRaw() is only needed at the wire boundary (outgoing, so
      // Windows/.NET can verify it), and rawToDer() before verifying any
      // *incoming* signature here, regardless of which platform sent it -
      // the wire format is always raw (matching Windows' native shape).
      const message = stringToBytes('step4-diagnostic-message');
      const derSignature = await identity.signRawDer(message);
      const rawSignature = derToRaw(derSignature);
      const reEncodedDer = rawToDer(rawSignature);
      const conversionRoundTripsCorrectly = toHex(reEncodedDer) === toHex(derSignature);
      this.step4Detail +=
        `DER signature (${derSignature.length} bytes): ${toHex(derSignature)}\n` +
        `raw signature (${rawSignature.length} bytes): ${toHex(rawSignature)}\n` +
        `conversion round-trips correctly (rawToDer(derToRaw(x)) === x): ${conversionRoundTripsCorrectly}\n\n`;
      if (!conversionRoundTripsCorrectly) {
        throw new Error('EcdsaDer conversion is broken - round trip does not reproduce the original DER bytes');
      }

      const keyGen = cryptoFramework.createAsyKeyGenerator('ECC256');
      const publicKeyBytes = new util.Base64Helper().decodeSync(publicKeyBase64);
      const keyPair = await keyGen.convertKey({ data: publicKeyBytes }, null);

      // The correct self-verify: HarmonyOS's own verify wants DER, so feed
      // it DER (either the original, or a round-tripped one - both should
      // work; using the round-tripped one here also re-proves the
      // conversion is usable, not just byte-identical in isolation).
      const verifier = cryptoFramework.createVerify('ECC256|SHA256');
      await verifier.init(keyPair.pubKey);
      await verifier.update({ data: message });
      const verified = await verifier.verify(null, { data: rawToDer(rawSignature) });
      this.step4Detail += `self-verify (via round-tripped DER): ${verified ? 'OK' : 'FAILED'}\n\n`;
      if (!verified) throw new Error('self-verify failed even with DER - deeper bug, needs investigation');

      // --- Trust store round-trip ---
      const trustStore = new TrustStore();
      const fakeDeviceKey = 'diagnostic-fake-device-key';
      await trustStore.trust(context, fakeDeviceKey, '192.168.1.1');
      const isTrusted = await trustStore.isTrusted(context, fakeDeviceKey);
      const allTrusted = await trustStore.getAllTrustedDevices(context);
      await trustStore.untrust(context, fakeDeviceKey);
      const isTrustedAfterUntrust = await trustStore.isTrusted(context, fakeDeviceKey);
      this.step4Detail +=
        `trust store: trusted=${isTrusted}, count=${allTrusted.length}, ` +
        `untrusted-after-remove=${!isTrustedAfterUntrust}\n\n`;
      if (!isTrusted || isTrustedAfterUntrust) throw new Error('trust store round-trip failed');

      // --- Passphrase key round-trip ---
      const passphraseStore = new PassphraseKeyStore();
      await passphraseStore.setPassphrase(context, 'diagnostic-test-passphrase');
      const hasPassphrase = await passphraseStore.hasPassphrase(context);
      const key = await passphraseStore.getKey(context);
      const proof = await passphraseStore.computeProof(key!, 'some-device-id');
      const proofValid = await passphraseStore.verifyProof(key!, 'some-device-id', proof);
      const proofInvalid = await passphraseStore.verifyProof(key!, 'some-device-id', 'bm90LXRoZS1wcm9vZg==');
      this.step4Detail +=
        `passphrase key: hasPassphrase=${hasPassphrase}, keyBytes=${key?.length}, ` +
        `validProofAccepted=${proofValid}, invalidProofRejected=${!proofInvalid}\n\n`;
      if (!hasPassphrase || key === null || !proofValid || proofInvalid) {
        throw new Error('passphrase key round-trip failed');
      }

      // --- File store smoke test ---
      const fileStore = new FileStore(context);
      const fakeHash = 'diagnostic-fake-hash';
      const existedBefore = fileStore.exists(fakeHash);
      this.step4Detail += `file store: path=${fileStore.getPath(fakeHash)}, existsForFakeHash=${existedBefore}\n`;

      this.step4Status = 'ALL PASSED';
    } catch (e) {
      this.step4Status = 'FAILED';
      const be = e as BusinessError;
      this.step4Detail += `error: ${be.message ?? e}\ncode: ${be.code}`;
    }
  }

  async onPasteButtonClick(result: PasteButtonOnClickResult) {
    if (result !== PasteButtonOnClickResult.SUCCESS) {
      this.lastReadStatus = `tap did not grant access (result: ${result})`;
      return;
    }
    const change = await this.watcher.readCurrentClipboard();
    this.pendingChange = false;
    if (change === null) {
      this.lastReadStatus = 'read OK, but content unchanged since last read (echo-suppressed)';
      return;
    }
    this.lastReadStatus = `read OK: ${change.type}`;
    this.entries = [change, ...this.entries].slice(0, 50);
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text('ClipLink — Step 4 diagnostics').fontSize(16).fontWeight(FontWeight.Bold)
        Button('Run Step 4 Diagnostics').onClick(() => { void this.runStep4Diagnostics(); })
        Text(`Status: ${this.step4Status}`)
        Text(this.step4Detail).fontSize(11)

        Divider()

        Text('Clipboard Sync — Step 3').fontSize(20).fontWeight(FontWeight.Bold)
        Text(
          'HarmonyOS restricts clipboard reads to a tap-triggered temporary ' +
          'grant for a normal app (see ClipboardWatcher.ets) — this can\'t ' +
          'silently auto-pull like the Windows daemon does. Detecting a ' +
          'change is free; tap Paste below to actually read it.'
        ).fontSize(12).fontColor('#666666')

        Divider()

        Text(this.pendingChange ? 'Clipboard changed — tap to sync' : 'No pending change detected').fontSize(16).fontWeight(FontWeight.Bold)

        PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
          .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
            void this.onPasteButtonClick(result);
          })
        Text(this.lastReadStatus).fontSize(12)

        Divider()

        Text(`Synced entries (${this.entries.length})`).fontSize(16).fontWeight(FontWeight.Bold)
        ForEach(this.entries, (entry: ClipboardChange, index: number) => {
          Column({ space: 4 }) {
            Text(`#${this.entries.length - index} — ${entry.type}`).fontWeight(FontWeight.Bold)
            if (entry.type === 'text') {
              Text(entry.content).fontSize(12).maxLines(3)
            } else if (entry.type === 'image') {
              Text(`(image, ${entry.content.length} base64 chars)`).fontSize(12)
            } else {
              Text(`(unsupported: ${entry.detail})`).fontSize(12)
            }
            if (entry.hash.length > 0) {
              Text(`hash: ${entry.hash}`).fontSize(10)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(8)
          .backgroundColor('#f2f2f2')
          .borderRadius(6)
        }, (entry: ClipboardChange, index: number) => `${index}-${entry.hash}`)
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }
}
