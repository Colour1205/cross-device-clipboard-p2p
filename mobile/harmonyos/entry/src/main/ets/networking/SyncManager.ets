// Step 8 of the build order in ../../../../README.md: full sync.
// Mirrors Program.cs's HandleMessage/SendHistoryBatch/ClipboardChanged
// broadcast logic. Scope matches step 8: "entry" and "history_batch" only
// - "file_chunk"/"file_request" are step 10 (need FileStore-backed
// chunked transfer, not implemented yet, logged rather than silently
// dropped).

import { common } from '@kit.AbilityKit';
import { PeerConnection } from './PeerConnection';
import { TrustStore } from '../identity/TrustStore';
import { HistoryAccess } from '../storage/HistoryAccess';
import { FileStore } from '../storage/FileStore';
import { ClipboardEntry, verifyEntry } from '../crypto/Signing';
import { applyEntryToClipboard, ApplyResult } from '../clipboard/ClipboardApply';

interface Envelope {
  Type: string;
  Payload: string;
}

export class SyncManager {
  private connections: Map<string, PeerConnection> = new Map();
  private history: HistoryAccess;
  private trustStore: TrustStore;
  private context: common.UIAbilityContext;
  private entryAppliedCallback: ((entry: ClipboardEntry, result: ApplyResult, fromPeer: boolean) => void) | null = null;
  private logCallback: ((message: string) => void) | null = null;

  constructor(fileStore: FileStore, trustStore: TrustStore, context: common.UIAbilityContext) {
    this.history = new HistoryAccess(fileStore);
    this.trustStore = trustStore;
    this.context = context;
  }

  onEntryApplied(callback: (entry: ClipboardEntry, result: ApplyResult, fromPeer: boolean) => void): void {
    this.entryAppliedCallback = callback;
  }

  onLog(callback: (message: string) => void): void {
    this.logCallback = callback;
  }

  get connectionCount(): number {
    return this.connections.size;
  }

  isConnected(deviceId: string): boolean {
    return this.connections.has(deviceId);
  }

  // Wires up a freshly-handshaken connection into ongoing sync: registers
  // it, starts listening, and sends our current history - same sequence
  // Program.cs runs right after both the accept loop and ConnectToPeer
  // complete a handshake.
  registerConnection(conn: PeerConnection): void {
    this.connections.set(conn.peerDeviceId, conn);
    conn.onMessage((msg: string) => { void this.handleMessage(msg); });
    conn.onDisconnected(() => {
      this.connections.delete(conn.peerDeviceId);
      this.logCallback?.(`peer disconnected: ${conn.peerDeviceId.slice(0, 20)}...`);
    });
    conn.listen();
    void this.sendHistoryBatch(conn);
  }

  private async sendHistoryBatch(conn: PeerConnection): Promise<void> {
    const history = await this.history.getHistory(this.context);
    const envelope: Envelope = { Type: 'history_batch', Payload: JSON.stringify(history) };
    await conn.send(JSON.stringify(envelope));
  }

  // Signs, broadcasts to every connected peer, and records locally - same
  // sequence as Program.cs's ClipboardChanged handler (file-copying
  // omitted, step 10 scope).
  async broadcastEntry(entry: ClipboardEntry): Promise<void> {
    const envelope: Envelope = { Type: 'entry', Payload: JSON.stringify(entry) };
    const json = JSON.stringify(envelope);
    for (const conn of this.connections.values()) {
      void conn.send(json);
    }
    await this.history.addToHistory(this.context, entry);
  }

  private async isVerifiedAndTrusted(entry: ClipboardEntry): Promise<boolean> {
    return (await verifyEntry(entry)) && (await this.trustStore.isTrusted(this.context, entry.DeviceId));
  }

  private async applyAndReport(entry: ClipboardEntry): Promise<void> {
    if (entry.Type === 'file') {
      // needs FileStore-backed chunked transfer - step 10
      this.entryAppliedCallback?.(entry, 'unsupported-type', true);
      return;
    }
    const result = await applyEntryToClipboard(entry);
    this.entryAppliedCallback?.(entry, result, true);
  }

  private async handleMessage(msg: string): Promise<void> {
    let envelope: Envelope;
    try {
      envelope = JSON.parse(msg) as Envelope;
    } catch (e) {
      this.logCallback?.('received invalid message from peer (bad JSON)');
      return;
    }

    if (envelope.Type === 'entry') {
      let entry: ClipboardEntry;
      try {
        entry = JSON.parse(envelope.Payload) as ClipboardEntry;
      } catch (e) {
        this.logCallback?.('received invalid message from peer (bad entry JSON)');
        return;
      }
      if (!(await this.isVerifiedAndTrusted(entry))) {
        this.logCallback?.('received message with invalid signature from peer');
        return;
      }
      await this.applyAndReport(entry);
      await this.history.addToHistory(this.context, entry);
    } else if (envelope.Type === 'history_batch') {
      let entries: ClipboardEntry[];
      try {
        entries = JSON.parse(envelope.Payload) as ClipboardEntry[];
      } catch (e) {
        this.logCallback?.('received invalid message from peer (bad history_batch JSON)');
        return;
      }
      for (const entry of entries) {
        if (!(await this.isVerifiedAndTrusted(entry))) {
          this.logCallback?.('received message with invalid signature from peer');
          continue; // skip just this bad entry, keep processing the rest of the batch
        }
        const isNew = await this.history.addToHistory(this.context, entry);
        if (isNew) {
          await this.applyAndReport(entry);
        }
      }
    } else if (envelope.Type === 'file_chunk' || envelope.Type === 'file_request') {
      this.logCallback?.(`received ${envelope.Type} - file transfer not implemented yet (step 10)`);
    } else {
      this.logCallback?.(`received message with unknown type from peer: ${envelope.Type}`);
    }
  }
}
