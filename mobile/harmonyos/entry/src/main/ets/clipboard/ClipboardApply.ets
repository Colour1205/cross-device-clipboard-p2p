// Step 8 of the build order in ../../../../README.md: full sync.
// Mirrors ClipboardSync.cs's setContent - applies a received (already
// verified) entry's content to the local system clipboard. Unlike reading
// (step 3), writing needs no restricted permission at all - setData/
// setDataSync carry no @permission tag in the SDK, confirmed by inspection.
//
// "file" type entries are intentionally not handled yet - that needs
// FileStore-backed content (chunked transfer, step 10). Logged clearly
// rather than silently dropped, same policy the rest of this project uses
// for known gaps.

import pasteboard from '@ohos.pasteboard';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { ClipboardEntry } from '../crypto/Signing';

const base64Helper = new util.Base64Helper();

export type ApplyResult = 'applied' | 'unsupported-type' | 'error';

export async function applyEntryToClipboard(entry: ClipboardEntry): Promise<ApplyResult> {
  try {
    if (entry.Type === 'text') {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, entry.Content);
      await pasteboard.getSystemPasteboard().setData(data);
      return 'applied';
    } else if (entry.Type === 'image') {
      const imageBytes = base64Helper.decodeSync(entry.Content);
      const imageSource = image.createImageSource(imageBytes.buffer as ArrayBuffer);
      const pixelMap = await imageSource.createPixelMap();
      const data = pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pixelMap);
      await pasteboard.getSystemPasteboard().setData(data);
      return 'applied';
    } else {
      // "file" - needs FileStore-backed chunked transfer, step 10
      return 'unsupported-type';
    }
  } catch (e) {
    return 'error';
  }
}
