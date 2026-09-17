// Step 3 of the build order in ../../../../README.md: clipboard read + watch.
//
// IMPORTANT platform difference from Windows (windows/daemon/Clipboard/ClipboardSync.cs)
// discovered while building this: ohos.permission.READ_PASTEBOARD is a
// restricted permission — declaring it in module.json5 makes the app
// UNINSTALLABLE without ACL provisioning this project doesn't have (confirmed
// on-device: `hdc shell bm install` fails outright with "grant request
// permissions failed"). There is no silent background auto-read on this
// platform for a normal app.
//
// The sanctioned workaround is the PasteButton security component: tapping
// it grants a temporary, dialog-free read privilege for that gesture only —
// no permission declaration needed at all. pasteboard.on('update') itself
// needs no permission either (confirmed: no @permission tag on it in the
// SDK, unlike getData()), so the real flow here is:
//   1. on('update') fires for free -> tell the UI "something changed".
//   2. User taps PasteButton -> read() runs inside that temporary grant.
// This means HarmonyOS sync can only ever be "detect + prompt", never
// "detect + silently pull", unlike Windows or (likely) Android. Worth
// keeping in mind for the eventual UI design in step 9.

import pasteboard from '@ohos.pasteboard';
import { image } from '@kit.ImageKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

const base64Helper = new util.Base64Helper();

export type ClipboardContentType = 'text' | 'image' | 'unsupported';

export interface ClipboardChange {
  type: ClipboardContentType;
  content: string; // text content, or base64-encoded PNG bytes for images
  hash: string;
  detail?: string; // e.g. the unsupported mime type list, or an error message
}

async function sha256Hex(data: Uint8Array): Promise<string> {
  const md = cryptoFramework.createMd('SHA256');
  await md.update({ data });
  const result = await md.digest();
  let out = '';
  for (let i = 0; i < result.data.length; i++) {
    out += result.data[i].toString(16).padStart(2, '0');
  }
  return out;
}

function utf8Bytes(s: string): Uint8Array {
  return new Uint8Array(Array.from(s).map(c => c.charCodeAt(0)));
}

function arrayBufferToBase64(buf: ArrayBuffer): string {
  return base64Helper.encodeToStringSync(new Uint8Array(buf));
}

export class ClipboardWatcher {
  private lastKnownHash: string | null = null;
  private listening = false;
  private changedCallback: (() => void) | null = null;
  private boundHandler = () => { this.changedCallback?.(); };

  // Fires on every pasteboard 'update' — free, no permission needed. Use
  // this only to prompt the user to tap the PasteButton; do not call
  // read() from in here, it will fail (no temporary grant active).
  onPasteboardChanged(callback: () => void): void {
    this.changedCallback = callback;
  }

  startListening(): void {
    if (this.listening) return;
    this.listening = true;
    pasteboard.getSystemPasteboard().on('update', this.boundHandler);
  }

  stopListening(): void {
    if (!this.listening) return;
    this.listening = false;
    pasteboard.getSystemPasteboard().off('update', this.boundHandler);
  }

  get isListening(): boolean {
    return this.listening;
  }

  // Only valid to call from inside a PasteButton onClick handler, in the
  // window after a SUCCESS result — that's what grants the temporary
  // pasteboard read privilege this needs.
  async readCurrentClipboard(): Promise<ClipboardChange | null> {
    try {
      const data = await pasteboard.getSystemPasteboard().getData();

      if (data.hasMimeType(pasteboard.MIMETYPE_PIXELMAP)) {
        const pixelMap = data.getPrimaryPixelMap();
        const packer = image.createImagePacker();
        const packed = await packer.packToData(pixelMap, { format: 'image/png', quality: 100 });
        const bytes = new Uint8Array(packed);
        const hash = await sha256Hex(bytes);
        if (hash === this.lastKnownHash) return null;
        this.lastKnownHash = hash;
        return { type: 'image', content: arrayBufferToBase64(packed), hash };
      } else if (data.hasMimeType(pasteboard.MIMETYPE_TEXT_PLAIN)) {
        const text = data.getPrimaryText();
        const hash = await sha256Hex(utf8Bytes(text));
        if (hash === this.lastKnownHash) return null;
        this.lastKnownHash = hash;
        return { type: 'text', content: text, hash };
      } else {
        return { type: 'unsupported', content: '', hash: '', detail: data.getMimeTypes().join(', ') };
      }
    } catch (e) {
      // Surfaced to the caller rather than swallowed — on a platform this
      // new, a permission or capability failure here is itself a finding.
      return { type: 'unsupported', content: '', hash: '', detail: `error: ${e}` };
    }
  }
}
