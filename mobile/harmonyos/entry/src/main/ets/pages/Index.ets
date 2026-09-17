// Step 3 of the build order in ../../../../README.md: clipboard read + watch.
// Real app screen (replaces the throwaway protocol-compatibility spike from
// step 2 — those findings are preserved in README.md and git history).
//
// Proves the clipboard side works end to end on-device: change detection,
// tap-triggered read (see ClipboardWatcher.ets for why), content hashing,
// text/image handling. No networking yet — that's steps 5+.

import { ClipboardWatcher, ClipboardChange } from '../clipboard/ClipboardWatcher';

@Entry
@Component
struct Index {
  @State pendingChange: boolean = false; // 'update' fired, not yet read
  @State entries: ClipboardChange[] = [];
  @State lastReadStatus: string = '';

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
