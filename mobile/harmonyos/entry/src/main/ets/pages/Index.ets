// Step 9 of the build order in ../../../../README.md: foreground-only
// lifecycle wiring + minimal real UI. Replaces the diagnostic dashboard
// steps 3-8 were built and verified against (that history is preserved in
// git log and README.md) with an actual app screen: a floating pill bottom
// nav (Synced / Devices / Me, Immersive Material per API 26.0.0's
// uiMaterial), edge-to-edge layout with manually-computed safe-area
// padding (see EntryAbility.ets for the full-screen window setup), elastic
// (Spring) over-scroll, and auto-connect to already-trusted peers as soon
// as their beacon is heard (the actual "foreground lifecycle" requirement
// - sync starts on its own when the app opens, no manual taps needed).
//
// Sync itself (steps 3, 8) is unchanged under the hood - this is a UI/
// orchestration layer on top of ClipboardWatcher, Discovery, TcpServer,
// PeerConnection, and SyncManager, all built and verified in earlier steps.

import hilog from '@ohos.hilog';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window, promptAction, curves } from '@kit.ArkUI';
import { scanBarcode } from '@kit.ScanKit';
import { systemShare } from '@kit.ShareKit';
import { util } from '@kit.ArkTS';
import pasteboard from '@ohos.pasteboard';
import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import picker from '@ohos.file.picker';
import uiMaterial from '@ohos.arkui.uiMaterial';
import unifiedDataChannel from '@ohos.data.unifiedDataChannel';
import { ClipboardWatcher } from '../clipboard/ClipboardWatcher';
import { DeviceIdentity } from '../identity/DeviceIdentity';
import { TrustStore, TrustedDevice } from '../identity/TrustStore';
import { PassphraseKeyStore } from '../identity/PassphraseKeyStore';
import { DeviceSettings } from '../identity/DeviceSettings';
import { FileStore } from '../storage/FileStore';
import { FilePayload } from '../storage/FilePayload';
import { Discovery, PeerBeacon } from '../networking/Discovery';
import { TcpServer, connectTcp } from '../networking/TcpTransport';
import { PeerConnection, TcpSocketAdapter, TcpSocketConnectionAdapter } from '../networking/PeerConnection';
import { SyncManager } from '../networking/SyncManager';
import { signEntry, ClipboardEntry } from '../crypto/Signing';
import { ApplyResult } from '../clipboard/ClipboardApply';
import socket from '@ohos.net.socket';

const base64Helper = new util.Base64Helper();

// Must match Program.cs's own default TCP port (args[1], defaulting to
// "52388" when the tray launcher starts it - see DaemonLauncher.cs, which
// only ever passes the label, never a port override). On the LAN this
// constant is irrelevant - the real listening port is always exchanged
// live via the discovery beacon's tcpPort field. Off-LAN (see
// reconnectOffLanPeers/Program.cs's own off-LAN loop) there's no beacon to
// learn a real port from, so both platforms fall back to whatever they
// assume the other's default is - if these two numbers disagree, every
// off-LAN reconnect attempt silently dials the wrong port and never
// connects, with nothing in the log to say why.
const TCP_PORT = 52388;

// Visible via `hdc shell hilog` - unlike Windows's Console.WriteLine, this
// app previously had NO console-visible debug output for its networking
// layer at all (only the in-app Activity Log, which requires the user to
// manually read and relay back). This is the HarmonyOS equivalent of the
// [conn]/[file] logging Program.cs already has, for the exact same reason:
// diagnosing a live connection issue without guessing.
const NET_LOG_DOMAIN = 0x0001;
const NET_LOG_TAG = 'ClipLinkNet';
function netLog(msg: string): void {
  hilog.info(NET_LOG_DOMAIN, NET_LOG_TAG, '%{public}s', msg);
}

// Merged view of a device for the UI - could be trusted, discovered (via
// beacon), connected, or any combination. A device the user has never
// trusted but whose beacon we've heard is "discovered only"; a trusted
// device we haven't heard from recently is "trusted only".
interface DeviceRow {
  deviceId: string;
  address: string | null;
  trusted: boolean;
  discovered: boolean;
  tcpPort: number | null;
  connected: boolean;
}

// A single synced clipboard item for the list UI - built from a verified
// ClipboardEntry (see SyncManager.onEntryApplied), not a raw log line.
interface SyncedItem {
  // Signature is unique per (content, type, deviceId, timestamp) - used as
  // the ForEach key below. `time` is deliberately truncated to HH:MM for
  // display and must NEVER be reused as a key: two copies from the same
  // source within the same minute would then collide on the same key,
  // and ArkUI would reuse the stale rendered node instead of updating its
  // text - the list visually "gets stuck" showing the first copy forever
  // even though new entries keep arriving and applying correctly.
  id: string;
  type: string;
  preview: string;
  content: string; // full, untruncated - what "Copy content"/"Select text" act on
  source: string;
  time: string;
  fromPeer: boolean;
}

// Wire shape for QR/pasted pairing exchange - matches windows/daemon/
// Networking/IpcMessage.cs's PairingInfo record exactly (PascalCase field
// names, since that's what .NET's default JSON serializer emits), so a
// code generated by this device can be scanned by a future Windows-side
// scanner and vice versa - a code Windows shows (via its "Show My QR Code"
// dialog, or pasted raw) can be scanned by this device.
interface PairingInfo {
  PublicKey: string;
  Address?: string;
}

const IMAGE_FILE_EXTENSIONS: string[] = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.heic', '.heif'];

// A 'file' entry is just "bytes with a name" at the wire level - whether it
// LOOKS like an image to the user only depends on its filename, not on the
// type tag. Image copying is common enough (Gallery/Files "Copy", or a
// Windows file-drop of a photo) that treating every one as an opaque
// undifferentiated file with no preview was a real gap, not a technicality.
function isImageFileName(name: string): boolean {
  const lower = name.toLowerCase();
  return IMAGE_FILE_EXTENSIONS.some(ext => lower.endsWith(ext));
}

function previewFor(entry: ClipboardEntry): string {
  if (entry.Type === 'text') {
    return entry.Content.length > 80 ? `${entry.Content.slice(0, 80)}...` : entry.Content;
  } else if (entry.Type === 'image') {
    return 'Image';
  } else if (entry.Type === 'file') {
    try {
      const payload = JSON.parse(entry.Content) as FilePayload;
      return payload.FileName;
    } catch (e) {
      return 'File';
    }
  }
  return entry.Content;
}

// Full-text view for the synced-item long-press menu's "Select text" option.
// A dialog rather than making the list card's own Text selectable in place,
// since the card only ever shows an 80-char preview - this shows the whole
// content, and .copyOption(LocalDevice) is what actually turns on ArkUI's
// native long-press-to-select-a-range behavior on a Text component.
@CustomDialog
struct SelectTextDialog {
  // Optional rather than a bare declaration: the framework injects this at
  // construction time (see showSelectTextDialog below, which never passes
  // it explicitly), but DevEco's Previewer linter
  // (mandatory-default-value-for-local-initialization) doesn't know that
  // and flags any non-optional field with no default - marking it optional
  // is what its own "correct code" examples do for exactly this case.
  controller?: CustomDialogController;
  content: string = '';

  build() {
    Column({ space: 12 }) {
      Scroll() {
        Text(this.content).fontSize(14).copyOption(CopyOptions.LocalDevice)
      }
      .width('100%')
      .constraintSize({ maxHeight: 320 })

      Button('Close').fontSize(13).onClick(() => { this.controller?.close(); })
    }
    .width('100%')
    .padding(16)
  }
}

// SaveButton (security component) has to be the actually-tapped element to
// get its temporary photoAccessHelper grant - it can't be triggered from a
// plain MenuItem's onClick. Wrapping it in its own small dialog (opened from
// the long-press menu's "Save to gallery" item) keeps it out of the menu
// itself while still reusing a pattern (CustomDialogController) already
// proven to work in this file.
@CustomDialog
struct SaveImageDialog {
  controller?: CustomDialogController;
  onSave: (result: SaveButtonOnClickResult) => void = () => {};

  build() {
    Column({ space: 16 }) {
      Text('Save this image to your gallery?').fontSize(14)
      SaveButton({ text: SaveDescription.SAVE_TO_GALLERY, buttonType: ButtonType.Capsule })
        .fontSize(14)
        .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
          this.onSave(result);
          this.controller?.close();
        })
      Button('Cancel').fontSize(13).onClick(() => { this.controller?.close(); })
    }
    .width('100%')
    .padding(20)
  }
}

@Entry
@Component
struct Index {
  @State ownDeviceId: string = '';
  @State receivedBeacons: PeerBeacon[] = [];
  @State trustedDevices: TrustedDevice[] = [];
  @State pendingChange: boolean = false;
  @State syncLog: string[] = [];
  @State syncedItems: SyncedItem[] = [];
  @State immersiveSupported: boolean = false;
  @State connectedCount: number = 0;
  @State topInsetVp: number = 0;
  @State bottomInsetVp: number = 0;
  @State currentTabIndex: number = 0;
  @State myPairingPayload: string = '';
  @State hasPassphrase: boolean = false;
  @State passphraseInput: string = '';
  // Manually-entered tailnet address for this device - see DeviceSettings.ets
  // for why this can't be auto-detected on HarmonyOS the way Windows does.
  @State tailscaleIp: string = '';
  @State savingTailscaleIp: boolean = false;
  @State settingPassphrase: boolean = false;
  @State scanStatus: string = '';
  // Which synced item (by id) is open in the full-screen detail view - a tap
  // (not long-press) sets this, and geometryTransition morphs the tapped
  // card into the detail view using this same id, "一镜到底" style (see
  // openItemDetail/itemDetailView below). File entries never set this (no
  // meaningful full-screen preview for them) - tapping one just plays the
  // shared clickEffect() feedback every card gets, per request.
  @State selectedItemId: string = '';
  // List vs 2-column WaterFlow grid for the Synced tab - see syncedTab's
  // viewModeToggleButton.
  @State syncedViewMode: string = 'list';
  // Two-finger pinch zoom on the item detail image - imageZoomScale is what
  // Image.scale() actually reads; imageZoomBase is the scale it was at when
  // the current pinch gesture started, since GestureEvent.scale is relative
  // to THAT gesture's start, not cumulative across separate pinches. Reset
  // on every open/close so zoom never carries over onto the next item.
  @State imageZoomScale: number = 1;
  private imageZoomBase: number = 1;
  // Pan offset, only meaningful once imageZoomScale > 1 - see zoomableImage.
  @State imageOffsetX: number = 0;
  @State imageOffsetY: number = 0;
  private imageOffsetBaseX: number = 0;
  private imageOffsetBaseY: number = 0;
  // Which Me screen is showing - a real separate screen per section
  // (pairing/QR, passcode, diagnostics, activity log) rather than one
  // combined page, per request.
  @State meScreen: 'main' | 'pairing' | 'passcode' | 'network' | 'diagnostics' | 'log' = 'main';
  // True only while the Pairing screen is open - see setMeScreen. This is
  // the live "I'm expecting to pair right now" signal broadcast in the LAN
  // beacon and checked by PeerConnection.create's relaxed trust gate; a
  // pairing handshake with an untrusted peer only proceeds at all when
  // this is true on BOTH ends independently.
  @State pairingOpen: boolean = false;
  // A connection that completed the full authenticated handshake but whose
  // peer wasn't already trusted - set only via the pairingOpen gate above,
  // and only resolved by the user tapping Accept/Reject on the prompt this
  // drives (see acceptPairing/rejectPairing). Not @State: PeerConnection
  // itself doesn't need reactive tracking, only the two id/address strings
  // that drive the prompt's UI do.
  @State pendingPairingPeerId: string = '';
  @State pendingPairingAddress: string = '';
  private pendingPairingConn: PeerConnection | null = null;
  @State pairByAddressInput: string = '';
  @State pairingInProgress: boolean = false;

  private watcher: ClipboardWatcher = new ClipboardWatcher();
  private discovery: Discovery = new Discovery();
  private tcpServer: TcpServer = new TcpServer();
  private trustStore: TrustStore = new TrustStore();
  private passphraseKeyStore: PassphraseKeyStore = new PassphraseKeyStore();
  private deviceSettings: DeviceSettings = new DeviceSettings();
  private syncManager: SyncManager | null = null;
  private fileStore: FileStore | null = null;
  private connectingTo: Set<string> = new Set();
  private offLanReconnectTimerId: number = -1;
  // Deterministic for a given (key, deviceId) pair - computed once whenever
  // the passphrase changes (or at startup, if one was already set) and
  // reused on every beacon tick, rather than re-deriving it every 2 seconds.
  // Discovery.start()'s getProof callback is synchronous (it runs inside a
  // setInterval tick), but computing an HMAC via cryptoFramework is async -
  // this cache is what bridges the two.
  private cachedProof: string | null = null;

  aboutToAppear(): void {
    this.immersiveSupported = uiMaterial.isImmersiveMaterialSupported();

    const context = getContext(this) as common.UIAbilityContext;
    window.getLastWindow(context).then((win: window.Window) => {
      const avoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.topInsetVp = px2vp(avoidArea.topRect.height);
      this.bottomInsetVp = px2vp(avoidArea.bottomRect.height);
    }).catch(() => { /* fall back to zero insets if the query fails */ });

    this.watcher.onPasteboardChanged(() => {
      this.pendingChange = true;
    });
    this.watcher.startListening();

    const fileStore = new FileStore(context);
    this.fileStore = fileStore;
    const syncManager = new SyncManager(fileStore, this.trustStore, context);
    syncManager.onEntryApplied((entry: ClipboardEntry, result: ApplyResult, fromPeer: boolean) => {
      const item: SyncedItem = {
        id: entry.Signature ?? `${entry.DeviceId}:${entry.Timestamp}`,
        type: entry.Type,
        preview: previewFor(entry),
        content: entry.Content,
        source: entry.DeviceId === this.ownDeviceId ? 'This device' : `${entry.DeviceId.slice(0, 12)}...`,
        time: entry.Timestamp.slice(11, 16),
        fromPeer,
      };
      this.syncedItems = [item, ...this.syncedItems].slice(0, 50);
    });
    syncManager.onLog((message: string) => {
      this.syncLog = [message, ...this.syncLog].slice(0, 30);
    });
    // The connections Map lives inside SyncManager and isn't itself
    // reactive - without this the Devices tab's connected-device count
    // never updated after the first render even though the underlying
    // count was always correct (see SyncManager.ets's onConnectionsChanged).
    syncManager.onConnectionsChanged((count: number) => {
      this.connectedCount = count;
    });
    this.syncManager = syncManager;

    this.tcpServer.onConnection((conn: socket.TCPSocketConnection) => {
      const identity = new DeviceIdentity();
      // Without capturing this, a device that only ever DIALED OUT to pair
      // (rather than being dialed) would never learn an address for
      // whoever just connected to it - meaning it could never later
      // reconnect off-LAN on its own (see reconnectOffLanPeers), only ever
      // be reconnected TO. getRemoteAddress() is what makes reconnect work
      // in both directions regardless of who initiated the original pairing.
      conn.getRemoteAddress()
        .then((addr: socket.NetAddress) => addr.address)
        .catch(() => null)
        .then((remoteAddress: string | null) => {
          PeerConnection.create(new TcpSocketConnectionAdapter(conn), identity, this.trustStore, context, this.pairingOpen, this.passphraseKeyStore)
            .then((peerConn: PeerConnection | null) => {
              if (peerConn === null) {
                conn.close().catch(() => { /* already closed - fine */ });
                return;
              }
              this.handleNewConnection(peerConn, remoteAddress);
            });
        });
    });
    this.tcpServer.start(TCP_PORT).catch((e: BusinessError) => {
      this.syncLog = [`TCP server error: ${e.message}`, ...this.syncLog].slice(0, 30);
    });

    this.discovery.onPeerDiscovered((beacon: PeerBeacon) => {
      const existingIndex = this.receivedBeacons.findIndex(b => b.deviceId === beacon.deviceId);
      if (existingIndex === -1) {
        this.receivedBeacons = [beacon, ...this.receivedBeacons].slice(0, 30);
      } else {
        const updated = this.receivedBeacons.slice();
        updated[existingIndex] = beacon;
        this.receivedBeacons = updated;
      }
      void this.maybeAutoTrustViaPassphrase(beacon);
      void this.maybeAutoConnect(beacon);
      void this.maybeConnectForPairing(beacon);
    });

    const identity = new DeviceIdentity();
    identity.getPublicKeyBase64().then((id: string) => {
      this.ownDeviceId = id;
      netLog(`ownDeviceId=${id}`);
      this.refreshPairingPayload();
      void this.discovery.start(id, TCP_PORT, () => this.cachedProof, () => this.tailscaleIp.length > 0 ? this.tailscaleIp : null, () => this.pairingOpen);
      void this.refreshPassphraseState();
      // Must run AFTER ownDeviceId is actually set, not just after this
      // .then() is scheduled - reconnectOffLanPeers's tie-breaker compares
      // against this.ownDeviceId, and calling it any earlier (e.g. from
      // aboutToAppear's own body, outside this callback) raced this
      // assignment: it ran with ownDeviceId still '' (empty string, before
      // the async key lookup resolved), so EVERY peer's key compared as
      // ">= ours" against the empty string and got skipped - a false
      // "let them reconnect to us instead" reading, not a real decision.
      // That's what made a cold start silently miss its immediate
      // reconnect attempt and sit waiting for the next 30s interval tick
      // instead, even though this call was already here.
      void this.reconnectOffLanPeers();
    });

    void this.refreshTrustedDevices();
    void this.loadTailscaleIp();
    // setInterval doesn't fire immediately - the explicit call above (now
    // correctly sequenced after ownDeviceId is set) is what actually makes
    // a just-reopened app try reconnecting right away instead of sitting
    // disconnected from any off-LAN (e.g. Tailscale) peer for up to 30s.
    this.offLanReconnectTimerId = setInterval(() => { void this.reconnectOffLanPeers(); }, 30000);
  }

  // ArkUI page-visibility hook - fires whenever this page becomes visible
  // again, including resuming the app from the background (aboutToAppear
  // does NOT re-run for that; it only runs once when the page is first
  // built, e.g. a genuine cold start). A backgrounded app can easily have
  // had its TCP connections quietly die (mobile OSes are aggressive about
  // suspending background network activity), so foregrounding is exactly
  // the other moment - besides a cold start - that deserves an immediate
  // reconnect attempt instead of waiting on the 30s interval. ownDeviceId
  // is already populated by now (it was set back when the page first
  // appeared), so unlike the cold-start call in aboutToAppear, there's no
  // ordering race to worry about here.
  onPageShow(): void {
    void this.reconnectOffLanPeers();
  }

  aboutToDisappear(): void {
    this.watcher.stopListening();
    this.discovery.stop();
    this.tcpServer.stop();
    if (this.offLanReconnectTimerId !== -1) {
      clearInterval(this.offLanReconnectTimerId);
      this.offLanReconnectTimerId = -1;
    }
  }

  // System/gesture back button - without this it always exits the app,
  // even when we're inside our own internal "pages" (the full-screen item
  // detail view, or a Me sub-screen). Returning true tells the framework
  // we handled it ourselves; returning false lets the default behavior
  // (exit) proceed, which is what we want once we're already back at a
  // top-level tab with nothing further to unwind.
  onBackPress(): boolean {
    if (this.selectedItemId.length > 0) {
      this.closeItemDetail();
      return true;
    }
    if (this.meScreen !== 'main') {
      this.setMeScreen('main');
      return true;
    }
    return false;
  }

  // Every navigation into/out of the Me tab's sub-screens goes through
  // this - not just a plain field assignment - because leaving/entering
  // 'pairing' has to flip pairingOpen in lockstep (see its own doc comment).
  private setMeScreen(screen: 'main' | 'pairing' | 'passcode' | 'network' | 'diagnostics' | 'log'): void {
    this.meScreen = screen;
    this.pairingOpen = screen === 'pairing';
  }

  private async refreshTrustedDevices(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    this.trustedDevices = await this.trustStore.getAllTrustedDevices(context);
  }

  // The actual "foreground lifecycle" requirement: connect automatically
  // to any already-trusted device as soon as its beacon is heard, no user
  // action needed. Tie-breaker matches Discovery.cs's Windows logic
  // (only the smaller-public-key side initiates) so both devices don't
  // simultaneously dial each other.
  private async maybeAutoConnect(beacon: PeerBeacon): Promise<void> {
    if (beacon.deviceId === this.ownDeviceId) return;
    if (this.syncManager?.isConnected(beacon.deviceId)) return;
    if (this.connectingTo.has(beacon.deviceId)) return;
    if (beacon.deviceId >= this.ownDeviceId) return;

    const context = getContext(this) as common.UIAbilityContext;
    const isTrusted = await this.trustStore.isTrusted(context, beacon.deviceId);
    if (!isTrusted) return;

    this.connectingTo.add(beacon.deviceId);
    try {
      await this.connectToBeacon(beacon);
    } finally {
      this.connectingTo.delete(beacon.deviceId);
    }
  }

  // Sibling to maybeAutoConnect, for UNTRUSTED peers - only attempts a
  // handshake at all when BOTH this device's own Pairing screen is open
  // (this.pairingOpen) AND the beacon says the sender's is too
  // (beacon.pairing) - two independent, live, local "I'm expecting to
  // pair right now" signals, not just one side's assumption. Same
  // tie-breaker as maybeAutoConnect so both sides don't dial each other
  // simultaneously; the handshake that results is what actually surfaces
  // the accept/reject prompt (see handleNewConnection).
  private async maybeConnectForPairing(beacon: PeerBeacon): Promise<void> {
    if (!this.pairingOpen || !beacon.pairing) return;
    if (beacon.deviceId === this.ownDeviceId) return;
    if (this.syncManager?.isConnected(beacon.deviceId)) return;
    if (this.connectingTo.has(beacon.deviceId)) return;
    if (this.pendingPairingConn !== null) return; // already have a candidate awaiting a decision
    if (beacon.deviceId >= this.ownDeviceId) return;

    const context = getContext(this) as common.UIAbilityContext;
    if (await this.trustStore.isTrusted(context, beacon.deviceId)) return; // maybeAutoConnect already handles this case

    this.connectingTo.add(beacon.deviceId);
    try {
      await this.connectToBeacon(beacon);
    } finally {
      this.connectingTo.delete(beacon.deviceId);
    }
  }

  // Single funnel for every freshly-created PeerConnection, whichever of
  // the three places created it (incoming TCP, LAN beacon dial, or manual
  // Pair by Address) - an already-trusted peer is registered immediately
  // like today; a pairing candidate (only possible because pairingOpen was
  // true - see PeerConnection.create) gets an explicit local accept/reject
  // prompt instead, never auto-registered.
  private handleNewConnection(peerConn: PeerConnection, address: string | null): void {
    netLog(`handleNewConnection: peer=${peerConn.peerDeviceId.slice(0, 16)}... address=${address ?? 'null'} wasAlreadyTrusted=${peerConn.wasAlreadyTrusted} newlyTrustedViaPassphrase=${peerConn.newlyTrustedViaPassphrase}`);
    if (peerConn.wasAlreadyTrusted) {
      if (peerConn.newlyTrustedViaPassphrase) {
        // The handshake itself carried a matching passphrase proof - same
        // auto-trust the LAN beacon already does passively, just over a
        // direct connection instead (works off-LAN, e.g. via Pair by
        // Address over Tailscale). Persist it so future reconnects don't
        // need the passphrase proof again.
        const context = getContext(this) as common.UIAbilityContext;
        void this.trustStore.trust(context, peerConn.peerDeviceId, address ?? undefined).then(() => { void this.refreshTrustedDevices(); });
        this.syncLog = [`auto-paired via passcode: ${peerConn.peerDeviceId.slice(0, 12)}...`, ...this.syncLog].slice(0, 30);
      } else {
        if (address !== null) {
          // Already trusted, but now we know a real address for this peer
          // (e.g. captured off an incoming connection whose remote endpoint
          // we just read, or a fresh dial) - back-fill it. trust() upserts
          // the address on an existing entry (see TrustStore.ets), so this
          // is what actually fixes a trust record that was written back
          // when the accept loop didn't capture an address at all (an old
          // bug - it always passed null), instead of leaving it permanently
          // stuck with no address to reconnect off-LAN with.
          const context = getContext(this) as common.UIAbilityContext;
          void this.trustStore.trust(context, peerConn.peerDeviceId, address).then(() => { void this.refreshTrustedDevices(); });
        }
        this.syncLog = [`connected: ${peerConn.peerDeviceId.slice(0, 12)}...`, ...this.syncLog].slice(0, 30);
      }
      this.syncManager?.registerConnection(peerConn);
      return;
    }
    if (this.pendingPairingConn !== null) {
      // Already showing a prompt for a different candidate - don't juggle
      // two at once; whichever arrived second just doesn't get to pair
      // this round (nothing stops them from opening pairing mode again).
      peerConn.close();
      return;
    }
    this.pendingPairingConn = peerConn;
    this.pendingPairingPeerId = peerConn.peerDeviceId;
    this.pendingPairingAddress = address ?? '';
    this.getUIContext().showAlertDialog({
      title: 'Pairing request',
      message: `${peerConn.peerDeviceId.slice(0, 20)}... wants to pair with this device. Only accept if you expect this - your Pairing screen being open is what let this request reach you at all.`,
      primaryButton: { value: 'Accept', action: () => { void this.acceptPairing(); } },
      secondaryButton: { value: 'Reject', action: () => { this.rejectPairing(); } },
      cancel: () => { this.rejectPairing(); },
    });
  }

  async acceptPairing(): Promise<void> {
    const conn = this.pendingPairingConn;
    if (conn === null) return;
    const context = getContext(this) as common.UIAbilityContext;
    const address = this.pendingPairingAddress.length > 0 ? this.pendingPairingAddress : undefined;
    await this.trustStore.trust(context, conn.peerDeviceId, address);
    await this.refreshTrustedDevices();
    this.pendingPairingConn = null;
    this.pendingPairingPeerId = '';
    this.pendingPairingAddress = '';
    this.syncLog = [`paired: ${conn.peerDeviceId.slice(0, 12)}...`, ...this.syncLog].slice(0, 30);
    this.syncManager?.registerConnection(conn);
    promptAction.showToast({ message: 'Paired.' });
  }

  rejectPairing(): void {
    this.pendingPairingConn?.close();
    this.pendingPairingConn = null;
    this.pendingPairingPeerId = '';
    this.pendingPairingAddress = '';
  }

  private async connectToBeacon(beacon: PeerBeacon): Promise<void> {
    try {
      const client = await connectTcp(beacon.senderIp, beacon.tcpPort);
      const identity = new DeviceIdentity();
      const context = getContext(this) as common.UIAbilityContext;
      const conn = await PeerConnection.create(new TcpSocketAdapter(client), identity, this.trustStore, context, this.pairingOpen, this.passphraseKeyStore);
      if (conn === null) {
        client.close().catch(() => { /* already closed - fine */ });
        this.syncLog = [`connect failed: ${beacon.deviceId.slice(0, 12)}...`, ...this.syncLog].slice(0, 30);
        return;
      }
      this.handleNewConnection(conn, beacon.senderIp);
    } catch (e) {
      const be = e as BusinessError;
      this.syncLog = [`connect error (${beacon.senderIp}:${beacon.tcpPort}): ${be.message}`, ...this.syncLog].slice(0, 30);
    }
  }

  // Off-LAN reconnect: for trusted peers whose only known address is a
  // cached one (e.g. a Tailscale IP, learned at pairing time or seen in a
  // beacon) rather than something LAN discovery can actually hear, dial out
  // periodically instead of waiting for a beacon that will never arrive
  // off-LAN - mirrors Program.cs's own off-LAN reconnect loop.
  private async reconnectOffLanPeers(): Promise<void> {
    if (this.ownDeviceId.length === 0) {
      // Identity hasn't resolved yet (this fires very early relative to the
      // async key lookup - both aboutToAppear's cold-start call, now
      // sequenced after it, AND onPageShow's, which is NOT, can still race
      // it). Every tie-breaker comparison below is against ownDeviceId, so
      // running this now would just compare against '' and get every
      // peer's key wrong (">= ours" for literally any non-empty key) -
      // bail instead of doing a guaranteed-wrong pass; the 30s interval or
      // the next onPageShow will retry once it's actually set.
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const devices = await this.trustStore.getTrustedDevicesWithAddress(context);
    netLog(`reconnectOffLanPeers: ownId=${this.ownDeviceId.slice(0, 16)}... ${devices.length} trusted-with-address device(s)`);
    for (const device of devices) {
      const shortId = device.publicKey.slice(0, 16);
      if (device.publicKey === this.ownDeviceId) continue;
      if (this.syncManager?.isConnected(device.publicKey)) {
        netLog(`  ${shortId}...: already connected, skipping`);
        continue;
      }
      if (this.connectingTo.has(device.publicKey)) {
        netLog(`  ${shortId}...: already attempting, skipping`);
        continue;
      }
      // Same tie-breaker as maybeAutoConnect - only the smaller-key side
      // initiates, so both sides don't simultaneously dial each other.
      if (device.publicKey >= this.ownDeviceId) {
        netLog(`  ${shortId}...: peer key >= ours, expecting THEM to reconnect to us instead`);
        continue;
      }
      if (device.address === undefined || device.address === null || device.address.length === 0) {
        netLog(`  ${shortId}...: no cached address, can't dial - needs one more successful connection to backfill`);
        continue;
      }

      netLog(`  ${shortId}...: dialing ${device.address}:${TCP_PORT}`);
      this.connectingTo.add(device.publicKey);
      try {
        const connected = await this.connectToAddress(device.address, TCP_PORT);
        netLog(`  ${shortId}...: dial ${connected ? 'succeeded' : 'failed'}`);
      } finally {
        this.connectingTo.delete(device.publicKey);
      }
    }
  }

  // Returns whether a connection was actually established (not whether
  // pairing succeeded - a pairing candidate still counts as "connected",
  // the accept/reject decision happens separately via handleNewConnection).
  // The periodic off-LAN reconnect loop ignores this; pairByAddress uses it
  // to give the user visible feedback instead of failing silently.
  private async connectToAddress(address: string, port: number): Promise<boolean> {
    try {
      const client = await connectTcp(address, port);
      const identity = new DeviceIdentity();
      const context = getContext(this) as common.UIAbilityContext;
      const conn = await PeerConnection.create(new TcpSocketAdapter(client), identity, this.trustStore, context, this.pairingOpen, this.passphraseKeyStore);
      if (conn === null) {
        netLog(`connectToAddress ${address}:${port}: TCP connected but handshake returned null (peer refused - not trusted, and not in pairing mode / no matching passphrase)`);
        client.close().catch(() => { /* already closed - fine */ });
        return false;
      }
      netLog(`connectToAddress ${address}:${port}: handshake succeeded, peer=${conn.peerDeviceId.slice(0, 16)}... wasAlreadyTrusted=${conn.wasAlreadyTrusted}`);
      this.handleNewConnection(conn, address);
      return true;
    } catch (e) {
      netLog(`connectToAddress ${address}:${port}: TCP connect failed - ${JSON.stringify(e)}`);
      return false;
    }
  }

  // Trusting a freshly-discovered device also immediately attempts to
  // connect to it (rather than waiting for its next beacon) - feels more
  // responsive when the user just tapped Trust specifically to connect.
  async trustAndConnect(beacon: PeerBeacon): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    await this.trustStore.trust(context, beacon.deviceId, beacon.senderIp);
    await this.refreshTrustedDevices();
    await this.connectToBeacon(beacon);
  }

  async untrustDevice(deviceId: string): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    await this.trustStore.untrust(context, deviceId);
    await this.refreshTrustedDevices();
    // Explicit confirmation matters here: a just-untrusted device doesn't
    // vanish from the Devices list if it's still actively beaconing (it
    // reappears as "discovered" with a Trust button instead of "trusted"
    // with Remove) - without this, tapping Remove on a device that's still
    // on the LAN looks like it silently did nothing.
    this.syncLog = [`untrusted ${deviceId.slice(0, 12)}...`, ...this.syncLog].slice(0, 30);
    promptAction.showToast({ message: `Removed ${deviceId.slice(0, 12)}...` });
  }

  // Recomputes the QR/manual pairing payload - called whenever ownDeviceId
  // or tailscaleIp changes, since the QR code needs to reflect whichever
  // is current rather than whatever was true when the screen first opened.
  private refreshPairingPayload(): void {
    const pairingInfo: PairingInfo = { PublicKey: this.ownDeviceId };
    if (this.tailscaleIp.length > 0) {
      pairingInfo.Address = this.tailscaleIp;
    }
    this.myPairingPayload = JSON.stringify(pairingInfo);
  }

  private async loadTailscaleIp(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    this.tailscaleIp = await this.deviceSettings.getTailscaleIp(context);
    this.refreshPairingPayload();
  }

  async saveTailscaleIp(): Promise<void> {
    if (this.savingTailscaleIp) return; // already running - ignore a double-tap
    this.savingTailscaleIp = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const trimmed = this.tailscaleIp.trim();
      await this.deviceSettings.setTailscaleIp(context, trimmed);
      this.tailscaleIp = trimmed;
      this.refreshPairingPayload();
      promptAction.showToast({ message: trimmed.length > 0 ? 'Tailscale IP saved.' : 'Tailscale IP cleared.' });
    } catch (e) {
      const be = e as BusinessError;
      promptAction.showToast({ message: `Failed to save: ${be.message ?? e}`, duration: 3000 });
    } finally {
      this.savingTailscaleIp = false;
    }
  }

  private async refreshPassphraseState(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    this.hasPassphrase = await this.passphraseKeyStore.hasPassphrase(context);
    if (this.hasPassphrase && this.ownDeviceId.length > 0) {
      const key = await this.passphraseKeyStore.getKey(context);
      if (key !== null) {
        this.cachedProof = await this.passphraseKeyStore.computeProof(key, this.ownDeviceId);
      }
    } else {
      this.cachedProof = null;
    }
  }

  async setPassphrase(): Promise<void> {
    if (this.settingPassphrase) return; // already running - ignore a double-tap
    const passphrase = this.passphraseInput.trim();
    if (passphrase.length === 0) {
      promptAction.showToast({ message: 'Enter a passcode first.' });
      return;
    }
    // PassphraseKeyStore.setPassphrase runs PBKDF2 at 210,000 iterations
    // (fixed to match the Windows side - see PassphraseKeyStore.ets) via
    // cryptoFramework, awaited per round - this can take several seconds
    // on-device. Without this pending state the button looked broken:
    // nothing visibly happened until it finally resolved.
    this.settingPassphrase = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await this.passphraseKeyStore.setPassphrase(context, passphrase);
      this.passphraseInput = '';
      await this.refreshPassphraseState();
      promptAction.showToast({ message: 'Passcode set — matching devices will auto-trust.', duration: 3000 });
    } catch (e) {
      const be = e as BusinessError;
      promptAction.showToast({ message: `Failed to set passcode: ${be.message ?? e}`, duration: 3000 });
    } finally {
      this.settingPassphrase = false;
    }
  }

  // Mirrors Program.cs's auto-trust block in discovery.PeerDiscovered: if
  // this device wasn't already trusted, but it proved knowledge of the same
  // passphrase we have configured, trust it now - an alternative to QR/
  // manual pairing for "these are all my own devices". Excludes our own id
  // for the same reason Windows does: UDP broadcasts loop back to the
  // sender on localhost.
  private async maybeAutoTrustViaPassphrase(beacon: PeerBeacon): Promise<void> {
    if (beacon.deviceId === this.ownDeviceId) return;
    if (beacon.proof === null) return;
    const context = getContext(this) as common.UIAbilityContext;
    if (await this.trustStore.isTrusted(context, beacon.deviceId)) return;
    const key = await this.passphraseKeyStore.getKey(context);
    if (key === null) return;
    const verified = await this.passphraseKeyStore.verifyProof(key, beacon.deviceId, beacon.proof);
    if (!verified) return;
    this.syncLog = [`auto-trusting ${beacon.deviceId.slice(0, 12)}... (shared passcode)`, ...this.syncLog].slice(0, 30);
    await this.trustStore.trust(context, beacon.deviceId, beacon.address ?? undefined);
    await this.refreshTrustedDevices();
  }

  // Manual pairing via QR: scans another device's pairing code (shown via
  // its own "Show My QR Code" - see myPairingPayload/QRCode in meTab below)
  // and trusts it. Accepts either the {PublicKey, Address} JSON payload
  // this device (and Windows's QrCodeForm) produce, or a bare public key
  // string, matching the same flexible-payload handling Program.cs's
  // trust_device IPC command does for a pasted key.
  // Scanning is now purely "how do I find the other device's address" -
  // NOT "trust it". It never writes to the trust store directly; it dials
  // the scanned address (same as Pair by Address below) and lets the
  // normal handleNewConnection accept/reject prompt decide. That prompt
  // only appears at all if THIS device's Pairing screen is open (which it
  // has to be, to reach this button) - and the connection only completes
  // in the first place if the OTHER device's Pairing screen is open too
  // (see PeerConnection.create's relaxed gate), so scanning someone's code
  // alone can no longer trust them unilaterally the way it used to.
  async scanToPair(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const result = await scanBarcode.startScanForResult(context);
      let pairingInfo: PairingInfo | null = null;
      try {
        pairingInfo = JSON.parse(result.originalValue) as PairingInfo;
      } catch (e) {
        // not JSON - fall through to bare-key handling below
      }
      const scannedKey: string = pairingInfo !== null && typeof pairingInfo.PublicKey === 'string' ? pairingInfo.PublicKey : '';
      const publicKey = scannedKey.length > 0 ? scannedKey : result.originalValue;
      if (publicKey.length === 0) {
        this.scanStatus = 'scanned code was empty';
        return;
      }
      const address: string | undefined = pairingInfo !== null && typeof pairingInfo.Address === 'string' ? pairingInfo.Address : undefined;
      if (address === undefined) {
        this.scanStatus = `${publicKey.slice(0, 12)}... has no address in its code - if it's on the same network, just keep this screen open and its beacon will trigger pairing automatically.`;
        return;
      }
      this.scanStatus = `Connecting to ${address}...`;
      const connected = await this.connectToAddress(address, TCP_PORT);
      this.scanStatus = connected
        ? `Reached ${address} - accept the pairing prompt on both devices to finish.`
        : `Could not reach ${address} - make sure the other device's Pairing screen is open too.`;
    } catch (e) {
      const be = e as BusinessError;
      if (be.code === 1000500002) {
        // user canceled the scan - routine, not an error
        return;
      }
      this.scanStatus = `scan failed: ${be.message}`;
    }
  }

  // Manual counterpart to scanToPair, for when there's no QR to scan (e.g.
  // Windows has no camera) - type/paste an address directly. Accepts either
  // a bare IP or the full {PublicKey,Address} pairing JSON (only the
  // address is actually used either way; the peer's real identity comes
  // from the signature-verified handshake, not from anything typed here).
  async pairByAddress(): Promise<void> {
    if (this.pairingInProgress) return;
    const raw = this.pairByAddressInput.trim();
    if (raw.length === 0) {
      promptAction.showToast({ message: 'Enter an address first.' });
      return;
    }
    let address = raw;
    try {
      const parsed = JSON.parse(raw) as PairingInfo;
      if (typeof parsed.Address === 'string' && parsed.Address.length > 0) {
        address = parsed.Address;
      }
    } catch (e) {
      // not JSON - treat the raw input as a bare address
    }
    this.pairingInProgress = true;
    try {
      const connected = await this.connectToAddress(address, TCP_PORT);
      promptAction.showToast({
        message: connected
          ? `Reached ${address} - accept the pairing prompt on both devices to finish.`
          : `Could not reach ${address} - make sure the other device's Pairing screen is open too.`,
        duration: 3000,
      });
    } finally {
      this.pairingInProgress = false;
    }
  }

  // See pairingScreen's "Copy Pairing Info" button - setData needs no
  // permission (unlike getData/PasteButton), so this can run from a plain
  // onClick with no security-component dance.
  async copyPairingPayload(): Promise<void> {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.myPairingPayload);
    await pasteboard.getSystemPasteboard().setData(data);
    promptAction.showToast({ message: 'Pairing info copied — paste it into Windows\' Trust a Device dialog.', duration: 3000 });
  }

  async onPasteButtonClick(result: PasteButtonOnClickResult) {
    if (result !== PasteButtonOnClickResult.SUCCESS) {
      promptAction.showToast({ message: 'Tap did not grant access — try again.' });
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const change = await this.watcher.readCurrentClipboard(context);
    this.pendingChange = false;
    if (change === null) {
      promptAction.showToast({ message: 'Clipboard unchanged since last sync.' });
      return;
    }
    if (change.type === 'unsupported') {
      promptAction.showToast({ message: `Unsupported clipboard content: ${change.detail}` });
      return;
    }

    const identity = new DeviceIdentity();
    const myDeviceId = await identity.getPublicKeyBase64();

    // "file" is different from text/image: the signed entry only ever
    // carries a small FilePayload descriptor (see storage/FilePayload.ets),
    // never the bytes themselves - those get cached into FileStore first
    // (so a file_request from a peer, or fulfilling our own pending entry,
    // can find them) and streamed separately by SyncManager.broadcastEntry.
    let entryContent = change.content;
    if (change.type === 'file') {
      const fileStore = this.fileStore;
      if (fileStore === null) {
        promptAction.showToast({ message: 'File store not ready yet — try again.' });
        return;
      }
      const bytes = base64Helper.decodeSync(change.content);
      const ab = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      if (!fileStore.exists(change.hash)) {
        const file = fs.openSync(fileStore.getPath(change.hash), fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, ab);
        } finally {
          fs.closeSync(file);
        }
      }
      const payload: FilePayload = { FileName: change.fileName ?? 'file', FileHash: change.hash, FileSize: bytes.byteLength };
      entryContent = JSON.stringify(payload);
    }

    const entry = await signEntry(identity, entryContent, change.type, myDeviceId);
    await this.syncManager?.broadcastEntry(entry);

    // broadcastEntry only sends to peers and records history - it never
    // touches syncedItems, which is what onEntryApplied (received-entry
    // path) populates. Without this, the device that actually captured
    // and sent something never saw it in its own Synced list at all -
    // only the receiving peer did.
    const item: SyncedItem = {
      id: entry.Signature ?? `${entry.DeviceId}:${entry.Timestamp}`,
      type: entry.Type,
      preview: previewFor(entry),
      content: entry.Content,
      source: 'This device',
      time: entry.Timestamp.slice(11, 16),
      fromPeer: false,
    };
    this.syncedItems = [item, ...this.syncedItems].slice(0, 50);

    const count = this.syncManager?.connectionCount ?? 0;
    promptAction.showToast({
      message: count > 0 ? `Synced ${change.type} to ${count} device(s).` : `Captured ${change.type} — no devices connected yet.`,
    });
  }

  async runSelfTest() {
    try {
      const identity = new DeviceIdentity();
      await identity.getPublicKeyBase64();
      const testBytes = new Uint8Array([1, 2, 3]);
      await identity.sign(testBytes);
      const context = getContext(this) as common.UIAbilityContext;
      await this.trustStore.isTrusted(context, 'self-test-probe');
      promptAction.showToast({ message: 'Self-test passed — identity, signing, and trust store all working.' });
    } catch (e) {
      const be = e as BusinessError;
      promptAction.showToast({ message: `Self-test failed: ${be.message ?? e}` });
    }
  }

  // "Copy" only makes sense for text - for image/file it used to dump the
  // raw base64/JSON descriptor onto the clipboard as literal text, which
  // was never useful. Those two types get Share + Save instead (see
  // shareItem/showSaveImageDialog/saveFileToDocuments below).
  copyItemContent(item: SyncedItem): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, item.content);
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => { promptAction.showToast({ message: 'Copied to clipboard.' }); })
      .catch(() => { promptAction.showToast({ message: 'Could not copy — try again.' }); });
  }

  showSelectTextDialog(item: SyncedItem): void {
    const dialogController: CustomDialogController = new CustomDialogController({
      builder: SelectTextDialog({ content: item.content }),
      alignment: DialogAlignment.Bottom,
    });
    dialogController.open();
  }

  // Real system share sheet (@kit.ShareKit's systemShare) - unlike
  // SaveButton, this is a normal API call, not gated behind a security
  // component. Images get materialized to a temp file first since
  // systemShare needs a URI, not raw base64.
  async shareItem(item: SyncedItem): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    try {
      let uri: string;
      let utd: string;
      if (item.type === 'image') {
        const path = `${context.cacheDir}/shared_image.png`;
        const bytes = base64Helper.decodeSync(item.content);
        const ab = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
        const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, ab);
        } finally {
          fs.closeSync(file);
        }
        uri = fileUri.getUriFromPath(path);
        utd = 'general.png';
      } else {
        const fileStore = this.fileStore;
        if (fileStore === null) {
          promptAction.showToast({ message: 'File store not ready — try again.' });
          return;
        }
        const payload = JSON.parse(item.content) as FilePayload;
        if (!fileStore.exists(payload.FileHash)) {
          promptAction.showToast({ message: "File hasn't finished downloading yet." });
          return;
        }
        uri = fileUri.getUriFromPath(fileStore.getPath(payload.FileHash));
        utd = 'general.file';
      }
      const sharedData = new systemShare.SharedData({ utd, uri });
      const controller = new systemShare.ShareController(sharedData);
      await controller.show(context, { previewMode: systemShare.SharePreviewMode.DETAIL });
    } catch (e) {
      promptAction.showToast({ message: 'Could not open share sheet.' });
    }
  }

  showSaveImageDialog(item: SyncedItem): void {
    const dialogController: CustomDialogController = new CustomDialogController({
      builder: SaveImageDialog({ onSave: (result: SaveButtonOnClickResult) => { void this.saveImageOnClick(item, result); } }),
      alignment: DialogAlignment.Bottom,
    });
    dialogController.open();
  }

  // Wired to a SaveButton (security component - see save_button.d.ts),
  // which is what actually grants the temporary photoAccessHelper access
  // this needs; it can't be invoked imperatively from a plain Button, the
  // SaveButton itself has to be the tapped component (see SaveImageDialog).
  async saveImageOnClick(item: SyncedItem, result: SaveButtonOnClickResult): Promise<void> {
    if (result !== SaveButtonOnClickResult.SUCCESS) {
      promptAction.showToast({ message: 'Save was not authorized.' });
      return;
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const uri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'png');
      const file = fs.openSync(uri, fs.OpenMode.WRITE_ONLY);
      try {
        const bytes = base64Helper.decodeSync(item.content);
        const ab = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
        fs.writeSync(file.fd, ab);
      } finally {
        fs.closeSync(file);
      }
      promptAction.showToast({ message: 'Saved to gallery.' });
    } catch (e) {
      promptAction.showToast({ message: 'Could not save image.' });
    }
  }

  // Files aren't media-library content, so this goes through
  // DocumentViewPicker.save() - a normal system file-save picker, not
  // gated behind a security component the way SaveButton/photoAccessHelper
  // is - confirmed against @ohos.file.picker.d.ts rather than assumed.
  async saveFileToDocuments(item: SyncedItem): Promise<void> {
    const fileStore = this.fileStore;
    if (fileStore === null) {
      promptAction.showToast({ message: 'File store not ready — try again.' });
      return;
    }
    try {
      const payload = JSON.parse(item.content) as FilePayload;
      if (!fileStore.exists(payload.FileHash)) {
        promptAction.showToast({ message: "File hasn't finished downloading yet." });
        return;
      }
      const context = getContext(this) as common.UIAbilityContext;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: Array<string> = await documentPicker.save({ newFileNames: [payload.FileName] });
      if (uris.length === 0) return; // user canceled the picker

      const srcFile = fs.openSync(fileStore.getPath(payload.FileHash), fs.OpenMode.READ_ONLY);
      const destFile = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        const buffer = new ArrayBuffer(256 * 1024);
        let bytesRead = fs.readSync(srcFile.fd, buffer);
        while (bytesRead > 0) {
          fs.writeSync(destFile.fd, buffer.slice(0, bytesRead) as ArrayBuffer);
          bytesRead = fs.readSync(srcFile.fd, buffer);
        }
      } finally {
        fs.closeSync(srcFile);
        fs.closeSync(destFile);
      }
      promptAction.showToast({ message: 'File saved.' });
    } catch (e) {
      promptAction.showToast({ message: 'Could not save file.' });
    }
  }

  // Tapping (not long-pressing) a text/image card morphs it into a
  // full-screen detail view via geometryTransition - the "一镜到底"
  // continuous-shot pattern from transitions-collection's
  // ListLongTakeTransition sample: the state change that swaps which view
  // is rendered has to happen INSIDE animateTo (not a .transition()
  // modifier alone) for the geometry interpolation to actually run.
  // Only meaningful for 'file' entries - a real 'image' entry already
  // carries its bytes inline as base64 (see itemDetailView/syncedItemCard).
  // Returns a file:// URI ArkUI's Image can load directly (same
  // fileUri.getUriFromPath pattern shareItem/saveFileToDocuments already
  // use), or null if this isn't an image file, or its bytes haven't
  // finished downloading yet (nothing to preview until they have).
  private imagePreviewUri(item: SyncedItem): string | null {
    if (item.type !== 'file') return null;
    try {
      const payload = JSON.parse(item.content) as FilePayload;
      if (!isImageFileName(payload.FileName)) return null;
      const fileStore = this.fileStore;
      if (fileStore === null || !fileStore.exists(payload.FileHash)) return null;
      return fileUri.getUriFromPath(fileStore.getPath(payload.FileHash));
    } catch (e) {
      return null;
    }
  }

  // 'image' entries only exist as in-memory base64 (see itemDetailView) -
  // dragging out to another app needs a real file:// URI, same as
  // shareItem's image branch, so materialize to a cache file first. Synchronous
  // because onDragStart itself is synchronous (it returns the drag preview
  // info directly, not a Promise) - fs's *Sync APIs are what make that
  // possible without restructuring the drag callback.
  private materializeDragImage(item: SyncedItem): string | null {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const path = `${context.cacheDir}/dragged_image.png`;
      const bytes = base64Helper.decodeSync(item.content);
      const ab = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, ab);
      } finally {
        fs.closeSync(file);
      }
      return fileUri.getUriFromPath(path);
    } catch (e) {
      return null;
    }
  }

  // Builds the UnifiedData payload a card's onDragStart hands to the
  // system so dropping it in another app (or another list position, once
  // reordering exists) carries real content - not just a picture of the
  // card. null means "nothing draggable yet" (e.g. a file entry whose
  // bytes haven't finished downloading), in which case onDragStart skips
  // setData and the drag simply carries no payload.
  private dragDataFor(item: SyncedItem): unifiedDataChannel.UnifiedData | null {
    if (item.type === 'text') {
      const text = new unifiedDataChannel.PlainText();
      text.textContent = item.content;
      return new unifiedDataChannel.UnifiedData(text);
    }
    if (item.type === 'image') {
      const uri = this.materializeDragImage(item);
      if (uri === null) return null;
      const image = new unifiedDataChannel.Image();
      image.imageUri = uri;
      return new unifiedDataChannel.UnifiedData(image);
    }
    if (item.type === 'file') {
      try {
        const payload = JSON.parse(item.content) as FilePayload;
        const fileStore = this.fileStore;
        if (fileStore === null || !fileStore.exists(payload.FileHash)) return null;
        const uri = fileUri.getUriFromPath(fileStore.getPath(payload.FileHash));
        if (isImageFileName(payload.FileName)) {
          const image = new unifiedDataChannel.Image();
          image.imageUri = uri;
          image.details = { name: payload.FileName };
          return new unifiedDataChannel.UnifiedData(image);
        }
        const file = new unifiedDataChannel.File();
        file.uri = uri;
        file.details = { name: payload.FileName };
        return new unifiedDataChannel.UnifiedData(file);
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  // File entries have no meaningful full-screen preview unless they're
  // recognizably an image (see imagePreviewUri) - otherwise tapping one
  // does nothing beyond the shared clickEffect() every card already gets.
  openItemDetail(item: SyncedItem): void {
    if (item.type === 'file' && this.imagePreviewUri(item) === null) return;
    this.imageZoomScale = 1;
    this.imageZoomBase = 1;
    this.imageOffsetX = 0;
    this.imageOffsetY = 0;
    this.imageOffsetBaseX = 0;
    this.imageOffsetBaseY = 0;
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 328, 36) }, () => {
      this.selectedItemId = item.id;
    });
  }

  closeItemDetail(): void {
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 328, 36) }, () => {
      this.selectedItemId = '';
    });
  }

  private deviceRows(): DeviceRow[] {
    const rows = new Map<string, DeviceRow>();
    for (const t of this.trustedDevices) {
      rows.set(t.publicKey, {
        deviceId: t.publicKey,
        address: t.address ?? null,
        trusted: true,
        discovered: false,
        tcpPort: null,
        connected: this.syncManager?.isConnected(t.publicKey) === true,
      });
    }
    for (const b of this.receivedBeacons) {
      if (b.deviceId === this.ownDeviceId) continue;
      const existing = rows.get(b.deviceId);
      if (existing) {
        existing.discovered = true;
        existing.tcpPort = b.tcpPort;
        existing.address = b.senderIp;
        existing.connected = this.syncManager?.isConnected(b.deviceId) === true;
      } else {
        rows.set(b.deviceId, {
          deviceId: b.deviceId,
          address: b.senderIp,
          trusted: false,
          discovered: true,
          tcpPort: b.tcpPort,
          connected: false,
        });
      }
    }
    return Array.from(rows.values());
  }

  private materialCard(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN });
  }

  // Per "组件适配沉浸光感" (component adaptation guide): buttons take
  // systemMaterial directly as a component-level immersive-material
  // attribute. interactive (press deforms) and lightEffect (light follows
  // the finger) are the tactile feedback replacing the plain default press
  // state - lightEffect.color is the one app accent color, reused here and
  // everywhere else it applies, rather than defaulting to white.
  private buttonMaterial(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      interactive: true,
      lightEffect: { color: $r('sys.color.brand') },
    });
  }

  // The long-press menu's own material - THICK is the documented default
  // for menus (vs. THIN for buttons/cards), for a more opaque backdrop
  // behind menu text.
  private menuMaterial(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THICK,
      interactive: true,
      lightEffect: { color: $r('sys.color.brand') },
    });
  }

  private typeCardBackground(type: string): ResourceColor {
    if (type === 'image') return '#F3E8FF';
    if (type === 'file') return '#FFF4E5';
    return '#EAF2FF'; // text
  }

  private typeAccentColor(type: string): ResourceColor {
    if (type === 'image') return '#9333EA';
    if (type === 'file') return '#C2790A';
    return $r('sys.color.brand');
  }

  // Real official long-press menu (bindContextMenu, confirmed to support
  // systemMaterial via ContextMenuOptions) instead of a hand-rolled
  // gesture+conditional-row hack - gets the native menu animation/backdrop
  // for free. "Copy" only for text; image/file get Share (real system
  // share sheet) and Save (gallery for images via a SaveButton-backed
  // dialog since SaveButton must be the tapped element itself; a document
  // picker for files, which needs no security component).
  @Builder
  itemActionMenu(item: SyncedItem) {
    Menu() {
      if (item.type === 'text') {
        MenuItem({ content: 'Copy' }).onClick(() => { this.copyItemContent(item); })
      } else {
        MenuItem({ content: 'Share' }).onClick(() => { void this.shareItem(item); })
        if (item.type === 'image') {
          MenuItem({ content: 'Save to gallery' }).onClick(() => { this.showSaveImageDialog(item); })
        } else {
          MenuItem({ content: 'Save file' }).onClick(() => { void this.saveFileToDocuments(item); })
        }
      }
    }
  }

  @Builder
  syncedItemCard(item: SyncedItem) {
    Row({ space: 12 }) {
      if (item.type === 'image') {
        Image(`data:image/png;base64,${item.content}`)
          .width(44)
          .height(44)
          .borderRadius(12)
          .objectFit(ImageFit.Cover)
      } else if (item.type === 'file' && this.imagePreviewUri(item) !== null) {
        Image(this.imagePreviewUri(item) as string)
          .width(44)
          .height(44)
          .borderRadius(12)
          .objectFit(ImageFit.Cover)
      } else if (item.type === 'file') {
        Text('📄')
          .fontSize(18)
          .width(44)
          .height(44)
          .textAlign(TextAlign.Center)
          .backgroundColor('#fdba74')
          .borderRadius(12)
      } else {
        Text(item.type.slice(0, 1).toUpperCase())
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .width(44)
          .height(44)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.typeAccentColor(item.type))
          .borderRadius(12)
      }

      Column({ space: 3 }) {
        Text(item.preview)
          .fontSize(14)
          .fontColor(this.typeAccentColor(item.type))
          .fontWeight(FontWeight.Medium)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${item.source} · ${item.time}`).fontSize(11).fontColor('#888888')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .borderRadius(18)
    .backgroundColor(this.typeCardBackground(item.type))
    .alignItems(VerticalAlign.Center)
    // Shared id with itemDetailView below - this is what makes the card
    // visually morph into the full-screen view instead of just cutting
    // between them ("一镜到底").
    .geometryTransition(item.id, { follow: true })
    // The "consistent animation for all clicks" - a single universal
    // attribute rather than a hand-built press-state gesture, so every
    // tappable surface (including file cards, which don't navigate
    // anywhere) gets identical feedback.
    .clickEffect({ level: ClickEffectLevel.MIDDLE })
    .onClick(() => { this.openItemDetail(item); })
    // Lets a card be dragged straight out into another app (e.g. dropping
    // a synced image into a chat) - draggable() + onDragStart() are the
    // universal attribute pair every draggable component uses (confirmed
    // against CommonMethod in common.d.ts); the actual payload is built by
    // dragDataFor() and attached via event.setData(), not the return value
    // - the return value only controls the drag preview/extra info, not
    // what gets dropped.
    .draggable(true)
    .onDragStart((event: DragEvent) => {
      const data = this.dragDataFor(item);
      if (data !== null) {
        event.setData(data);
      }
      return { extraInfo: item.preview };
    })
    // systemMaterial belongs in bindContextMenu's OWN options (third
    // argument), not as an attribute on the Menu() inside the builder -
    // that's the actual mechanism ContextMenuOptions exposes, confirmed
    // against common.d.ts; setting it on Menu() itself (the earlier
    // attempt) silently did nothing, which is why the menu had no material.
    // hapticFeedbackMode gives a tactile tick the instant the menu opens -
    // the framework's own built-in option (confirmed in common.d.ts), not
    // a manual vibrator call. Needs ohos.permission.VIBRATE declared in
    // module.json5 (a normal/system_grant permission, unlike
    // READ_PASTEBOARD - safe to just declare, no ACL/AppGallery process).
    .bindContextMenu(this.itemActionMenu(item), ResponseType.LongPress, {
      systemMaterial: this.menuMaterial(),
      hapticFeedbackMode: HapticFeedbackMode.ENABLED,
    })
  }

  // Grid-mode counterpart to syncedItemCard - an item with a real image
  // (native 'image' type, or a 'file' entry imagePreviewUri recognizes)
  // gets the photo featured full-width on top with the caption below,
  // instead of the same fixed 44x44 thumbnail every card uses in list
  // mode. Deliberately doesn't set a height on the Image: with only width
  // set, ArkUI sizes it by the image's own aspect ratio, so a portrait
  // photo's card ends up taller than a landscape one's - that varying
  // per-card height is what makes WaterFlow actually lay out as a masonry
  // grid instead of a uniform one. Non-image items don't get this
  // treatment - the compact row card already fits a 2-column cell fine
  // without manufacturing a fake masonry effect for plain text.
  @Builder
  syncedGridCard(item: SyncedItem) {
    if (item.type !== 'image' && this.imagePreviewUri(item) === null) {
      this.syncedItemCard(item)
    } else {
      Column({ space: 6 }) {
        Image(item.type === 'image' ? `data:image/png;base64,${item.content}` : this.imagePreviewUri(item) as string)
          .width('100%')
          .borderRadius(12)
        Text(item.preview)
          .fontSize(13)
          .fontColor(this.typeAccentColor(item.type))
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 4, right: 4 })
        Text(`${item.source} · ${item.time}`)
          .fontSize(10)
          .fontColor('#888888')
          .padding({ left: 4, right: 4, bottom: 4 })
      }
      .width('100%')
      .padding(8)
      .borderRadius(18)
      .backgroundColor(this.typeCardBackground(item.type))
      .alignItems(HorizontalAlign.Start)
      // Same shared-id morph, click/drag/long-press wiring as
      // syncedItemCard - only one of the two card variants is ever
      // mounted for a given item at a time (list XOR grid mode), so
      // reusing item.id here doesn't conflict with the other variant.
      .geometryTransition(item.id, { follow: true })
      .clickEffect({ level: ClickEffectLevel.MIDDLE })
      .onClick(() => { this.openItemDetail(item); })
      .draggable(true)
      .onDragStart((event: DragEvent) => {
        const data = this.dragDataFor(item);
        if (data !== null) {
          event.setData(data);
        }
        return { extraInfo: item.preview };
      })
      .bindContextMenu(this.itemActionMenu(item), ResponseType.LongPress, {
        systemMaterial: this.menuMaterial(),
        hapticFeedbackMode: HapticFeedbackMode.ENABLED,
      })
    }
  }

  // Full-screen "one shot" detail view for a tapped text/image card - see
  // openItemDetail/closeItemDetail and the geometryTransition id shared
  // with syncedItemCard above. Takes the item directly as a parameter
  // rather than looking it up via a getter inside the @Builder - a getter
  // call from inside a @Builder is what was actually producing the blank
  // black screen (the caller already has the item in hand from the same
  // find() it used to decide whether to show this view at all, so this
  // also avoids a redundant second lookup).
  // Two-finger pinch zoom, clamped to [1x, 4x] - imageZoomScale/imageZoomBase
  // are reset in openItemDetail so a previous item's zoom never carries over.
  // GestureEvent.scale is relative to THIS gesture's start, not cumulative,
  // which is why onActionStart snapshots the current scale into
  // imageZoomBase rather than multiplying onto imageZoomScale directly.
  @Builder
  zoomableImage(src: string) {
    Image(src)
      .width('100%')
      .constraintSize({ maxHeight: '65%' })
      .objectFit(ImageFit.Contain)
      .borderRadius(20)
      .scale({ x: this.imageZoomScale, y: this.imageZoomScale })
      .translate({ x: this.imageOffsetX, y: this.imageOffsetY })
      // Parallel, not Sequence - pinch and pan need to both be live at once
      // (pinching with two fingers while drifting them sideways is one
      // continuous gesture to the user, not two separate ones).
      .gesture(
        GestureGroup(GestureMode.Parallel,
          PinchGesture()
            .onActionStart(() => { this.imageZoomBase = this.imageZoomScale; })
            .onActionUpdate((event: GestureEvent) => {
              this.imageZoomScale = Math.max(1, Math.min(4, this.imageZoomBase * event.scale));
            }),
          // offsetX/offsetY are relative to THIS gesture's start, same
          // reasoning as the pinch scale handling above - onActionStart
          // snapshots the running offset so each new drag adds on top of
          // where the last one left off instead of resetting to it.
          PanGesture()
            .onActionStart(() => {
              this.imageOffsetBaseX = this.imageOffsetX;
              this.imageOffsetBaseY = this.imageOffsetY;
            })
            .onActionUpdate((event: GestureEvent) => {
              // Only meaningful once zoomed in - at 1x the image already
              // fills the frame, and panning it here would just be a
              // confusing swipe that goes nowhere (this is also what makes
              // it safe to have Tabs.scrollable(false) above: panning an
              // unzoomed image is a no-op, not a competing gesture).
              if (this.imageZoomScale <= 1) return;
              // offsetX/offsetY come back in real screen vp, but translate()
              // is applied to THIS node's own (pre-scale) coordinate space -
              // once .scale() is also active, the same requested translate
              // paints as visibly less screen movement the higher the scale
              // goes (exactly the "faster at low zoom, slower at high zoom"
              // reported). Multiplying the raw offset by the current scale
              // is what cancels that out and keeps the point under the
              // finger actually under the finger at any zoom level.
              this.imageOffsetX = this.imageOffsetBaseX + event.offsetX * this.imageZoomScale;
              this.imageOffsetY = this.imageOffsetBaseY + event.offsetY * this.imageZoomScale;
            })
            .onActionEnd(() => {
              if (this.imageZoomScale <= 1) {
                this.imageOffsetX = 0;
                this.imageOffsetY = 0;
              }
            })
        )
      )
  }

  @Builder
  itemDetailView(item: SyncedItem) {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 16 }) {
        if (item.type === 'image') {
          this.zoomableImage(`data:image/png;base64,${item.content}`)
        } else if (this.imagePreviewUri(item) !== null) {
          this.zoomableImage(this.imagePreviewUri(item) as string)
        } else {
          Scroll() {
            Text(item.content).fontSize(16).fontColor(Color.White).copyOption(CopyOptions.LocalDevice)
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.TopStart)
        }
        Text(`${item.source} · ${item.time}`).fontSize(12).fontColor('#AAAAAA')
      }
      .width('100%')
      .height('100%')
      // Room at the top for the back button, and the same bottom safe-area
      // reservation every other tab uses (this.bottomInsetVp + 80) - the
      // floating tab bar pill still overlaps this view (barOverlap applies
      // to the whole Tabs, not per-tab), so without it long text/an image
      // can render underneath the pill instead of stopping clear of it.
      .padding({ left: 20, right: 20, top: this.topInsetVp + 76, bottom: this.bottomInsetVp + 80 })
      .justifyContent(FlexAlign.Center)

      // Consistent top-left back button, immersive-material like every
      // other back control in the app (see subScreenHeader) - not a
      // bottom-centered "Close" that could end up under the nav pill.
      Button() {
        Text('‹').fontSize(22).fontColor(Color.White)
      }
      .type(ButtonType.Circle)
      .width(44)
      .height(44)
      // Chain ORDER matters, confirmed against the Button reference doc's
      // own 示例9: .systemMaterial() called BEFORE .backgroundColor() lets
      // backgroundColor layer on top as a translucent tint; called after
      // (the earlier version), it gets force-cleared to transparent by the
      // material call - which is why the button vanished entirely. The
      // color also has to be genuinely translucent (some non-zero,
      // non-opaque alpha) or there's nothing for the blur to visually
      // differ from.
      .systemMaterial(this.buttonMaterial())
      .backgroundColor('#66ffffff')
      .margin({ left: 16, top: this.topInsetVp + 16 })
      .onClick(() => { this.closeItemDetail(); })
    }
    .width('100%')
    .height('100%')
    // Reverted the immersive-material backdrop experiment: systemMaterial
    // is meant to sit behind a simple leaf component (a button, a tab bar)
    // per every official example - wrapping real foreground content
    // (Image/Text/Scroll) in it directly isn't the documented pattern and
    // was actually washing the content out. A flat dark surface is the
    // correct backdrop for a full-bleed content viewer; the button above
    // still gets the immersive treatment.
    .backgroundColor('#000000')
    .geometryTransition(this.selectedItemId, { follow: true })
    .transition(TransitionEffect.OPACITY)
  }

  // Big page title at the top of a tab's content - the bottom tab bar
  // labels the destination, this labels where you currently are, which is
  // its own separate thing most apps show.
  @Builder
  pageTitle(text: string) {
    Text(text)
      .fontSize(28)
      .fontWeight(FontWeight.Bold)
      .width('100%')
  }

  // Small pill toggle - highlighted when it's the active mode, transparent
  // otherwise. Two of these side by side (List / Grid) is the whole control.
  @Builder
  viewModeToggleButton(label: string, mode: string) {
    Text(label)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.syncedViewMode === mode ? Color.White : $r('sys.color.brand'))
      .backgroundColor(this.syncedViewMode === mode ? $r('sys.color.brand') : Color.Transparent)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(12)
      .onClick(() => { this.syncedViewMode = mode; })
  }

  @Builder
  syncedTab() {
    // Mutually exclusive with the detail view (an if/else, not an overlay
    // Stack) - geometryTransition expects the shared-id element to exist
    // in only ONE of the two branches at a time. The earlier Stack-overlay
    // version kept the card AND the detail view mounted simultaneously
    // with the same id, which is what produced the blank black screen
    // instead of an actual morph.
    if (this.selectedItemId.length === 0) {
      Column({ space: 8 }) {
        Row() {
          // pageTitle's own Text is hard-coded to width('100%') (it's meant
          // to be the sole content of its row everywhere else it's used) -
          // sitting next to the toggle in the same Row, that claimed the
          // ENTIRE row's width for itself and pushed the toggle off past the
          // right edge instead of just sizing to its own text. Wrapping it
          // in a layoutWeight(1) container caps it to its fair share (parent
          // width minus the toggle's own size) instead of the full width,
          // which is what actually leaves room for the toggle to render
          // on-screen. Blank() alone doesn't fix this - it competes for
          // remaining space same as any flexible child, but pageTitle's
          // Text isn't flexible, it's hard-set to 100%, so Blank() would
          // still be racing against a fixed-at-100% sibling and lose.
          Row() { this.pageTitle('Synced') }.layoutWeight(1)
          Row({ space: 6 }) {
            this.viewModeToggleButton('List', 'list')
            this.viewModeToggleButton('Grid', 'waterfall')
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: this.topInsetVp + 16 })

        Column({ space: 8 }) {
          Text(this.pendingChange ? 'Clipboard changed — tap to sync' : 'Clipboard up to date').fontSize(15).fontWeight(FontWeight.Medium)
          PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
            .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => { void this.onPasteButtonClick(result); })
        }
        .width('100%')
        .padding(16)
        .borderRadius(18)
        .systemMaterial(this.materialCard())
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 16, right: 16 })

        if (this.syncedItems.length === 0) {
          Text('Nothing synced yet.').fontSize(12).fontColor('#999999').padding({ left: 16, right: 16 })
        } else if (this.syncedViewMode === 'list') {
          List({ space: 10 }) {
            ForEach(this.syncedItems, (item: SyncedItem) => {
              ListItem() { this.syncedItemCard(item) }
            }, (item: SyncedItem) => item.id)
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: this.bottomInsetVp + 80 })
          .edgeEffect(EdgeEffect.Spring)
          .layoutWeight(1)
        } else {
          // Same WaterFlow pattern devicesTab uses below - a 2-column grid
          // rather than a single stacked list, per request.
          WaterFlow() {
            ForEach(this.syncedItems, (item: SyncedItem) => {
              FlowItem() { this.syncedGridCard(item) }
            }, (item: SyncedItem) => item.id)
          }
          .columnsTemplate('1fr 1fr')
          .columnsGap(10)
          .rowsGap(10)
          .padding({ left: 16, right: 16, bottom: this.bottomInsetVp + 80 })
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    } else if (this.syncedItems.find(i => i.id === this.selectedItemId)) {
      this.itemDetailView(this.syncedItems.find(i => i.id === this.selectedItemId) as SyncedItem)
    }
  }

  @Builder
  deviceCard(row: DeviceRow) {
    Column({ space: 6 }) {
      Row()
        .width(28)
        .height(28)
        .borderRadius(9)
        .backgroundColor(row.connected ? $r('sys.color.brand') : '#c7c7c2')
      Text(row.address ?? 'unknown IP').fontSize(13).fontWeight(FontWeight.Medium)
      Text(row.connected ? 'Connected' : row.trusted ? 'Trusted' : 'Discovered')
        .fontSize(10).fontColor(row.connected ? '#16A34A' : '#8A8A86')

      if (!row.trusted && row.discovered) {
        Button('Trust').fontSize(12).fontColor($r('sys.color.brand')).systemMaterial(this.buttonMaterial()).backgroundColor('#330A59F7').width('100%').onClick(() => {
          const beacon = this.receivedBeacons.find(b => b.deviceId === row.deviceId);
          if (beacon) void this.trustAndConnect(beacon);
        })
      } else if (row.trusted) {
        Button('Remove').fontSize(12).fontColor($r('sys.color.brand')).systemMaterial(this.buttonMaterial()).backgroundColor('#330A59F7').width('100%').onClick(() => { void this.untrustDevice(row.deviceId); })
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(18)
    // Connected devices get a distinct accent-tinted background rather
    // than blending into the same plain white every other card uses.
    .backgroundColor(row.connected ? '#EAF2FF' : '#FFFFFF')
    .alignItems(HorizontalAlign.Start)
    .clickEffect({ level: ClickEffectLevel.MIDDLE })
  }

  @Builder
  devicesTab() {
    Column({ space: 8 }) {
      Column() { this.pageTitle('Devices') }
        .width('100%')
        .padding({ left: 16, right: 16, top: this.topInsetVp + 16 })
      Text(`${this.connectedCount} device(s) connected`).fontSize(14).fontColor('#666666')
        .width('100%')
        .padding({ left: 16, right: 16 })

      if (this.deviceRows().length === 0) {
        Text('No devices yet. Trusted devices and nearby devices on the same network will show up here.')
          .fontSize(12).fontColor('#999999')
          .padding({ left: 16, right: 16 })
      } else {
        // WaterFlow, per request - a 2-column masonry grid rather than a
        // single stacked list, since device cards have different heights
        // (a discovered-only card gains a Trust button the others don't).
        WaterFlow() {
          ForEach(this.deviceRows(), (row: DeviceRow) => {
            FlowItem() { this.deviceCard(row) }
          }, (row: DeviceRow) => row.deviceId)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(10)
        .rowsGap(10)
        .padding({ left: 16, right: 16, bottom: this.bottomInsetVp + 80 })
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // Small caption label above a settings group, matching the grouped-list
  // convention (SubHeader-style) instead of every row/card looking equal
  // weight.
  @Builder
  sectionHeader(text: string) {
    Text(text.toUpperCase())
      .fontSize(11)
      .fontColor('#8A8A86')
      .fontWeight(FontWeight.Medium)
      .padding({ left: 4, bottom: 2 })
  }

  // A single row inside a grouped settings card - consistent height/padding
  // and a trailing chevron when it navigates, so every row in the list
  // reads as the same kind of control.
  @Builder
  settingsRow(title: string, value: string, navigates: boolean, onTap: () => void) {
    Row({ space: 8 }) {
      Text(title).fontSize(14).layoutWeight(1)
      if (value.length > 0) {
        Text(value).fontSize(13).fontColor('#8A8A86')
      }
      if (navigates) {
        Text('›').fontSize(16).fontColor('#8A8A86')
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 13, bottom: 13 })
    .clickEffect({ level: ClickEffectLevel.MIDDLE })
    .onClick(onTap)
  }

  // A sub-screen's own back-button header, factored out since every Me
  // sub-screen (pairing, passcode, diagnostics, log) needs the identical one.
  @Builder
  subScreenHeader(title: string) {
    Row({ space: 8 }) {
      Button('‹').fontSize(18).fontColor($r('sys.color.brand')).systemMaterial(this.buttonMaterial()).backgroundColor('#330A59F7')
        .onClick(() => { this.setMeScreen('main'); })
      Text(title).fontSize(20).fontWeight(FontWeight.Bold)
    }
    .width('100%')
    .padding({ bottom: 8 })
  }

  // Primary "Me" screen: identity + a real settings list, one row per
  // section (pairing/QR, passcode, diagnostics, activity log), each
  // navigating to its OWN separate screen - not one page with everything
  // clumped together.
  @Builder
  meTab() {
    if (this.meScreen === 'main') {
      Scroll() {
        Column({ space: 16 }) {
          this.pageTitle('Me')

          this.sectionHeader('Device')
          Column() {
            Column({ space: 4 }) {
              Text('Your device ID').fontSize(12).fontColor('#8A8A86')
              Text(this.ownDeviceId).fontSize(11).copyOption(CopyOptions.LocalDevice)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(14)
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor($r('sys.color.comp_background_list_card'))

          this.sectionHeader('Pairing')
          Column() {
            this.settingsRow('QR code & scan', '', true, () => { this.setMeScreen('pairing'); })
            Divider().color('#00000010')
            this.settingsRow('Passcode auto-trust', this.hasPassphrase ? 'On' : 'Off', true, () => { this.setMeScreen('passcode'); })
            Divider().color('#00000010')
            this.settingsRow('Tailscale IP', this.tailscaleIp.length > 0 ? this.tailscaleIp : 'Not set', true, () => { this.setMeScreen('network'); })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor($r('sys.color.comp_background_list_card'))

          this.sectionHeader('Support')
          Column() {
            this.settingsRow('Diagnostics', '', true, () => { this.setMeScreen('diagnostics'); })
            Divider().color('#00000010')
            this.settingsRow('Activity log', `${this.syncLog.length}`, true, () => { this.setMeScreen('log'); })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor($r('sys.color.comp_background_list_card'))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: this.topInsetVp + 16, bottom: this.bottomInsetVp + 80 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)
      .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.START)))
    } else if (this.meScreen === 'pairing') {
      this.pairingScreen()
    } else if (this.meScreen === 'passcode') {
      this.passcodeScreen()
    } else if (this.meScreen === 'network') {
      this.networkScreen()
    } else if (this.meScreen === 'diagnostics') {
      this.diagnosticsScreen()
    } else {
      this.activityLogScreen()
    }
  }

  // Pairing: QR display + scan, mirrors Windows's QrCodeForm/
  // TrustDeviceForm pair but adapted to a device that actually has a
  // camera - scanning replaces Windows's paste-the-key fallback.
  @Builder
  pairingScreen() {
    Scroll() {
      Column({ space: 16 }) {
        this.subScreenHeader('Pairing')
        Column({ space: 8 }) {
          Text('This screen open = pairable.').fontSize(13).fontWeight(FontWeight.Medium)
          Text('A pairing request only reaches this device while this screen is open, and only completes once you tap Accept here - keep it open on BOTH devices at the same time while pairing. Leaving this screen closes the window; nothing pairs silently in the background.')
            .fontSize(12)
            .fontColor('#999999')
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .alignItems(HorizontalAlign.Start)

        Column({ space: 12 }) {
          if (this.myPairingPayload.length > 0) {
            QRCode(this.myPairingPayload)
              .width(220)
              .height(220)
              .color(Color.Black)
              .backgroundColor(Color.White)
              .borderRadius(16)
          }
          Text('Scan this on another device (with its own Pairing screen open) to find it.').fontSize(12).fontColor('#999999')
          Button('Scan a Device\'s QR Code').fontSize(14).fontColor($r('sys.color.brand')).systemMaterial(this.buttonMaterial()).backgroundColor('#330A59F7')
            .onClick(() => { void this.scanToPair(); })
          if (this.scanStatus.length > 0) {
            Text(this.scanStatus).fontSize(12).fontColor('#666666')
          }
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))

        // Windows has no camera to scan the QR above with (see
        // TrustDeviceForm.cs) - this covers that, plus any cross-network
        // (Tailscale) case where you'd rather paste an address than type
        // it. Either way this only ever FINDS the peer; accept/reject still
        // decides whether it's actually trusted, same as everything else
        // on this screen.
        Column({ space: 10 }) {
          Text('Pair by address').fontSize(14).fontWeight(FontWeight.Medium)
          Text('No camera on the other device (e.g. Windows)? Type or paste its address - or its pairing text copied below - here instead.')
            .fontSize(12)
            .fontColor('#999999')
          TextInput({ placeholder: 'e.g. 100.x.x.x or pasted pairing text', text: this.pairByAddressInput })
            .type(InputType.Normal)
            .fontSize(14)
            .enabled(!this.pairingInProgress)
            .onChange((value: string) => { this.pairByAddressInput = value; })
          Button(this.pairingInProgress ? 'Connecting...' : 'Pair by Address')
            .fontSize(14)
            .fontColor($r('sys.color.brand'))
            .systemMaterial(this.buttonMaterial())
            .backgroundColor('#330A59F7')
            .enabled(!this.pairingInProgress)
            .onClick(() => { void this.pairByAddress(); })
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .alignItems(HorizontalAlign.Start)

        Column({ space: 10 }) {
          Text('This device\'s pairing info').fontSize(14).fontWeight(FontWeight.Medium)
          Text('Copy this and send it to the other device (e.g. paste it into ITS Pair by Address field above) so it knows where to find this one.')
            .fontSize(12)
            .fontColor('#999999')
          Button('Copy Pairing Info').fontSize(14).fontColor($r('sys.color.brand')).systemMaterial(this.buttonMaterial()).backgroundColor('#330A59F7')
            .enabled(this.myPairingPayload.length > 0)
            .onClick(() => { void this.copyPairingPayload(); })
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topInsetVp + 16, bottom: this.bottomInsetVp + 80 })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END)))
  }

  // Passcode auto-trust: mirrors Windows's PasscodeForm/PassphraseAuth -
  // any device that later enters the same passcode auto-trusts this one
  // over the LAN beacon, no QR needed.
  @Builder
  passcodeScreen() {
    Scroll() {
      Column({ space: 16 }) {
        this.subScreenHeader('Passcode auto-trust')
        Column({ space: 10 }) {
          Text('Devices entering the same passcode trust each other automatically.').fontSize(12).fontColor('#999999')
          if (this.hasPassphrase) {
            Text('Passcode is set on this device.').fontSize(13).fontColor('#16A34A')
          } else {
            TextInput({ placeholder: 'Enter a shared passcode', text: this.passphraseInput })
              .type(InputType.Password)
              .fontSize(14)
              .enabled(!this.settingPassphrase)
              .onChange((value: string) => { this.passphraseInput = value; })
            Button(this.settingPassphrase ? 'Setting...' : 'Set Passcode')
              .fontSize(14)
              .fontColor($r('sys.color.brand'))
              .systemMaterial(this.buttonMaterial())
              .backgroundColor('#330A59F7')
              .enabled(!this.settingPassphrase)
              .onClick(() => { void this.setPassphrase(); })
          }
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topInsetVp + 16, bottom: this.bottomInsetVp + 80 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END)))
  }

  // HarmonyOS has no sandboxed way to ask the Tailscale app for this
  // device's own tailnet IP the way the Windows daemon shells out to
  // `tailscale ip -4` - see DeviceSettings.ets. This is the manual
  // substitute: paste it in once (Tailscale's own app shows it), and it
  // gets broadcast in the LAN beacon and the QR/manual pairing payload
  // exactly like Windows's auto-detected one would, so other devices can
  // cache it and reconnect over it once you're off the same LAN.
  @Builder
  networkScreen() {
    Scroll() {
      Column({ space: 16 }) {
        this.subScreenHeader('Tailscale IP')
        Column({ space: 10 }) {
          Text('HarmonyOS can\'t detect this automatically - copy your tailnet IP from the Tailscale app and paste it here so other devices can reach this one off your local network.').fontSize(12).fontColor('#999999')
          TextInput({ placeholder: 'e.g. 100.x.x.x', text: this.tailscaleIp })
            .type(InputType.Normal)
            .fontSize(14)
            .enabled(!this.savingTailscaleIp)
            .onChange((value: string) => { this.tailscaleIp = value; })
          Button(this.savingTailscaleIp ? 'Saving...' : 'Save')
            .fontSize(14)
            .fontColor($r('sys.color.brand'))
            .systemMaterial(this.buttonMaterial())
            .backgroundColor('#330A59F7')
            .enabled(!this.savingTailscaleIp)
            .onClick(() => { void this.saveTailscaleIp(); })
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topInsetVp + 16, bottom: this.bottomInsetVp + 80 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END)))
  }

  @Builder
  diagnosticsScreen() {
    Scroll() {
      Column({ space: 16 }) {
        this.subScreenHeader('Diagnostics')
        Column() {
          this.settingsRow('Run self-test', '', false, () => { void this.runSelfTest(); })
          Divider().color('#00000010')
          this.settingsRow('Immersive material', this.immersiveSupported ? 'Supported' : 'Not supported', false, () => {})
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topInsetVp + 16, bottom: this.bottomInsetVp + 80 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END)))
  }

  // syncLog is where every connect/disconnect/trust/untrust/auto-trust
  // event gets recorded (see e.g. untrustDevice, connectToBeacon,
  // maybeAutoTrustViaPassphrase).
  @Builder
  activityLogScreen() {
    Scroll() {
      Column({ space: 16 }) {
        this.subScreenHeader('Activity log')
        if (this.syncLog.length === 0) {
          Text('Nothing logged yet.').fontSize(12).fontColor('#999999')
        } else {
          Column({ space: 6 }) {
            ForEach(this.syncLog, (line: string, index: number) => {
              Text(line).fontSize(12).fontColor('#999999')
            }, (line: string, index: number) => `${index}-${line}`)
          }
          .width('100%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topInsetVp + 16, bottom: this.bottomInsetVp + 80 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END)))
  }

  // Root cause of the persistently-unreadable tab labels, found in Huawei's
  // own "设置沉浸式系统材质反色" (immersive material color-invert) sample:
  // colorInvert only auto-adjusts text/icon color for BottomTabBarStyle's
  // labelStyle/iconStyle (which use color-invert-aware resource tokens like
  // $r('sys.color.font_primary')) - it does NOT apply to an arbitrary
  // custom @Builder's Text with a hardcoded hex fontColor, which is what
  // every earlier attempt here used. Hardcoded hex can't be "inverted" by
  // the material at all. Switching to the framework's own tab-bar-style
  // class, with colorInvert: true on the material, is what actually makes
  // this work per the sample.
  tabBarStyle(text: string): BottomTabBarStyle {
    return BottomTabBarStyle.of($r('sys.media.ohos_icon_mask_svg'), text)
      .labelStyle({ selectedColor: $r('sys.color.brand'), unselectedColor: $r('sys.color.font_primary') })
      .iconStyle({ selectedColor: $r('sys.color.brand'), unselectedColor: $r('sys.color.font_primary') });
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // Matches the official API 26.0.0 barFloatingStyle sample (ts-container-tabs
      // reference doc, "示例24 TabBar悬浮样式") as closely as possible. Two things
      // an earlier guess-and-check pass got wrong:
      // - barMode/barHeight/scrollable aren't part of the canonical sample at all
      //   and aren't needed for a fixed 3-tab bar.
      // - Tabs has defaulted expandSafeArea to
      //   expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM]) since API 11.
      //   An explicit .expandSafeArea([SafeAreaType.SYSTEM]) (no edge argument,
      //   which expands ALL edges) plus a manually-computed barBottomMargin were
      //   fighting that built-in behavior instead of relying on it.
      Tabs({ index: this.currentTabIndex, barPosition: BarPosition.End }) {
        TabContent() { this.syncedTab() }
          .tabBar(this.tabBarStyle('Synced'))
        TabContent() { this.devicesTab() }
          .tabBar(this.tabBarStyle('Devices'))
        TabContent() { this.meTab() }
          .tabBar(this.tabBarStyle('Me'))
      }
      // Off: a left/right swipe on the Synced tab is claimed by the zoomed
      // image's pan gesture (see zoomableImage) - if Tabs also treated that
      // swipe as "switch tab", the two would fight over the same gesture.
      // Tapping the tab bar itself still switches tabs fine; this only
      // removes the swipe-to-switch shortcut.
      .scrollable(false)
      .barOverlap(true)
      .barFloatingStyle({
        adaptToHandedness: true,
        // maskColor/maskHeight fade list content into the floating bar's
        // material rather than letting it cut off abruptly underneath -
        // the "gradient blur" edge treatment the immersive material doc's
        // samples use around floating system bars.
        maskColor: Color.Transparent,
        maskHeight: 24,
        systemMaterial: new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.THIN,
          applyShadow: true,
          interactive: true,
          // One accent color reused everywhere (see buttonMaterial) instead
          // of the default white light-follows-finger glow.
          lightEffect: { color: $r('sys.color.brand') },
          // Needs THIN or ULTRA_THIN to take effect (see doc comment above) -
          // THIN is already what we use, so this was a one-line gap the whole time.
          colorInvert: true,
        }),
      })
      .width('100%')
      .height('100%')
      .onChange((index: number) => { this.currentTabIndex = index; })

      // Status bar treatment: the app draws edge-to-edge (see
      // EntryAbility.ets's setWindowLayoutFullScreen), so without this the
      // area behind the status bar icons is just raw scrolling content -
      // this gives it the same immersive-material blur as the bottom bar,
      // for a consistent top/bottom edge treatment.
      Row()
        .width('100%')
        .height(this.topInsetVp)
        .systemMaterial(new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THIN, colorInvert: true }))
        .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
  }
}
