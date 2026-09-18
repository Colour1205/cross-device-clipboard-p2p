// Step 8 of the build order in ../../../../README.md: full sync.
// Mirrors windows/daemon/Storage/HistoryAccess.cs — same 25-item cap,
// oldest-first eviction, same file-blob cleanup on eviction for file-type
// entries. Preferences only stores flat ValueType entries, so (same
// tradeoff as TrustStore.ets) the whole history is kept as one
// JSON-serialized array under a single key.

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { ClipboardEntry } from '../crypto/Signing';
import { FileStore } from './FileStore';
import { FilePayload } from './FilePayload';

const PREFERENCES_NAME = 'cliplink_history';
const HISTORY_KEY = 'entries';
const MAX_HISTORY_ITEMS = 25;

export class HistoryAccess {
  private fileStore: FileStore;

  constructor(fileStore: FileStore) {
    this.fileStore = fileStore;
  }

  private async getPrefs(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    return preferences.getPreferences(context, PREFERENCES_NAME);
  }

  async getHistory(context: common.UIAbilityContext): Promise<ClipboardEntry[]> {
    const prefs = await this.getPrefs(context);
    const json = prefs.getSync(HISTORY_KEY, '[]') as string;
    try {
      return JSON.parse(json) as ClipboardEntry[];
    } catch (e) {
      // corrupt preferences value — regenerate rather than crash, same
      // policy HistoryAccess.cs/TrustStore.cs use on the Windows side
      return [];
    }
  }

  private async saveHistory(context: common.UIAbilityContext, entries: ClipboardEntry[]): Promise<void> {
    const prefs = await this.getPrefs(context);
    prefs.putSync(HISTORY_KEY, JSON.stringify(entries));
    await prefs.flush();
  }

  private isSameEntry(a: ClipboardEntry, b: ClipboardEntry): boolean {
    return a.Content === b.Content && a.Type === b.Type && a.DeviceId === b.DeviceId
      && a.Timestamp === b.Timestamp && a.Signature === b.Signature;
  }

  // Returns true only if the entry was genuinely new (not a duplicate) -
  // matches HistoryAccess.cs's addToHistory return contract, which callers
  // rely on to decide whether to also apply/re-broadcast an entry.
  async addToHistory(context: common.UIAbilityContext, entry: ClipboardEntry): Promise<boolean> {
    const entries = await this.getHistory(context);
    if (entries.some(e => this.isSameEntry(e, entry))) {
      return false;
    }
    entries.push(entry);
    await this.trimToLimit(entries);
    await this.saveHistory(context, entries);
    return true;
  }

  // Oldest-first eviction once over the cap - also deletes the backing
  // FileStore blob for evicted file-type entries, same as Windows.
  private async trimToLimit(entries: ClipboardEntry[]): Promise<void> {
    while (entries.length > MAX_HISTORY_ITEMS) {
      let oldestIndex = 0;
      for (let i = 1; i < entries.length; i++) {
        if (entries[i].Timestamp < entries[oldestIndex].Timestamp) {
          oldestIndex = i;
        }
      }
      const oldest = entries.splice(oldestIndex, 1)[0];
      if (oldest.Type === 'file') {
        try {
          const payload = JSON.parse(oldest.Content) as FilePayload;
          this.fileStore.delete(payload.FileHash);
        } catch (e) {
          // malformed descriptor — nothing coherent to clean up
        }
      }
    }
  }

  async clearHistory(context: common.UIAbilityContext): Promise<void> {
    await this.saveHistory(context, []);
  }
}
