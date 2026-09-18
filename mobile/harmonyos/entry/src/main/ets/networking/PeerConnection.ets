// Step 6/7 of the build order in ../../../../README.md: handshake +
// session encryption, then trust store integration. Mirrors
// windows/daemon/Networking/PeerConnection.cs's authenticated ECDH
// handshake, AES-256-GCM session transport, and trust enforcement - refuse
// the connection outright if the peer's claimed identity isn't trusted,
// checked at the same point in the flow Windows checks it (right after
// parsing their handshake message, before spending effort verifying the
// signature or deriving a session key for a peer we'd refuse anyway).

import socket from '@ohos.net.socket';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { DeviceIdentity, verifyRawSignature } from '../identity/DeviceIdentity';
import { TrustStore } from '../identity/TrustStore';
import * as AesGcm from '../crypto/AesGcm';

const base64Helper = new util.Base64Helper();
const decoder = util.TextDecoder.create('utf-8');

interface HandshakeMessage {
  EphemeralPublicKey: string;
  IdentityPublicKey: string;
  Signature: string;
}

// Both socket.TCPSocket (outbound, from connectTcp) and
// socket.TCPSocketConnection (inbound, from TcpServer.onConnection) expose
// this same shape - captured explicitly here rather than relying on
// implicit structural compatibility between two separate SDK types, so
// PeerConnection.create() works identically for whichever side initiated
// the TCP connection (matches PeerConnection.cs: the handshake itself has
// no notion of "client" vs "server" role, both sides just write-then-read).
interface TcpLike {
  onMessage(callback: (info: socket.SocketMessageInfo) => void): void;
  onClose(callback: () => void): void;
  send(options: socket.TCPSendOptions): Promise<void>;
  close(): Promise<void>;
}

// ArkTS has no structural typing (arkts-no-structural-typing) - a
// socket.TCPSocket or socket.TCPSocketConnection can't be passed where
// TcpLike is expected just because their shapes match; they need an
// explicit adapter. Thin pass-through wrappers, one per concrete SDK type.
export class TcpSocketAdapter implements TcpLike {
  private inner: socket.TCPSocket;
  constructor(inner: socket.TCPSocket) {
    this.inner = inner;
  }
  onMessage(callback: (info: socket.SocketMessageInfo) => void): void {
    this.inner.on('message', callback);
  }
  onClose(callback: () => void): void {
    this.inner.on('close', callback);
  }
  send(options: socket.TCPSendOptions): Promise<void> {
    return this.inner.send(options);
  }
  close(): Promise<void> {
    return this.inner.close();
  }
}

export class TcpSocketConnectionAdapter implements TcpLike {
  private inner: socket.TCPSocketConnection;
  constructor(inner: socket.TCPSocketConnection) {
    this.inner = inner;
  }
  onMessage(callback: (info: socket.SocketMessageInfo) => void): void {
    this.inner.on('message', callback);
  }
  onClose(callback: () => void): void {
    this.inner.on('close', callback);
  }
  send(options: socket.TCPSendOptions): Promise<void> {
    return this.inner.send(options);
  }
  close(): Promise<void> {
    return this.inner.close();
  }
}

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  const md = cryptoFramework.createMd('SHA256');
  await md.update({ data });
  return (await md.digest()).data;
}

// Reassembles newline-delimited lines out of a TCPSocket's raw message
// chunks, and supports async pull (readLine) - matches the semantics of
// .NET's StreamReader.ReadLineAsync() (returns null on clean close) closely
// enough for this protocol's purposes. Used for the whole connection
// lifetime, handshake and session phase alike, same as the Windows side
// reuses one StreamReader/StreamWriter throughout.
class TcpLineChannel {
  private client: TcpLike;
  private buffer: Uint8Array = new Uint8Array(0);
  private pendingLines: string[] = [];
  private waiters: Array<(line: string | null) => void> = [];
  private closed = false;

  constructor(client: TcpLike) {
    this.client = client;
    client.onMessage((info: socket.SocketMessageInfo) => {
      this.handleChunk(info.message);
    });
    client.onClose(() => {
      this.closed = true;
      this.flushWaiters(null);
    });
  }

  private handleChunk(chunk: ArrayBuffer): void {
    const bytes = new Uint8Array(chunk);
    const combined = new Uint8Array(this.buffer.length + bytes.length);
    combined.set(this.buffer, 0);
    combined.set(bytes, this.buffer.length);
    this.buffer = combined;

    let idx = this.buffer.indexOf(10); // '\n'
    while (idx !== -1) {
      const lineBytes = this.buffer.slice(0, idx);
      this.buffer = this.buffer.slice(idx + 1);
      let line = decoder.decodeToString(lineBytes);
      if (line.endsWith('\r')) line = line.slice(0, -1);
      this.deliverLine(line);
      idx = this.buffer.indexOf(10);
    }
  }

  private deliverLine(line: string): void {
    const waiter = this.waiters.shift();
    if (waiter) {
      waiter(line);
    } else {
      this.pendingLines.push(line);
    }
  }

  private flushWaiters(value: string | null): void {
    while (this.waiters.length > 0) {
      this.waiters.shift()?.(value);
    }
  }

  async readLine(): Promise<string | null> {
    if (this.pendingLines.length > 0) {
      return this.pendingLines.shift()!;
    }
    if (this.closed) return null;
    return new Promise<string | null>((resolve) => {
      this.waiters.push(resolve);
    });
  }

  async writeLine(line: string): Promise<void> {
    await this.client.send({ data: line + '\n' });
  }

  close(): void {
    this.client.close().catch(() => { /* already closed - fine */ });
  }
}

export class PeerConnection {
  private messageCallback: ((message: string) => void) | null = null;
  private disconnectedCallback: (() => void) | null = null;
  private channel: TcpLineChannel;
  private sessionKey: Uint8Array;
  public readonly peerDeviceId: string;

  private constructor(channel: TcpLineChannel, sessionKey: Uint8Array, peerDeviceId: string) {
    this.channel = channel;
    this.sessionKey = sessionKey;
    this.peerDeviceId = peerDeviceId;
  }

  // Returns null (never throws for a bad/malformed/untrusted peer) on any
  // handshake failure - same contract as PeerConnection.cs's CreateAsync.
  static async create(client: TcpLike, myIdentity: DeviceIdentity, trustStore: TrustStore, context: common.UIAbilityContext): Promise<PeerConnection | null> {
    const channel = new TcpLineChannel(client);

    try {
      const ephemeralKeyGen = cryptoFramework.createAsyKeyGenerator('ECC256');
      const ephemeralKeyPair = await ephemeralKeyGen.generateKeyPair();
      const ephemeralPubBytes = ephemeralKeyPair.pubKey.getEncoded().data;
      const mySignature = await myIdentity.sign(ephemeralPubBytes);
      const myIdentityPublicKey = await myIdentity.getPublicKeyBase64();

      const myHandshake: HandshakeMessage = {
        EphemeralPublicKey: base64Helper.encodeToStringSync(ephemeralPubBytes),
        IdentityPublicKey: myIdentityPublicKey,
        Signature: base64Helper.encodeToStringSync(mySignature),
      };
      await channel.writeLine(JSON.stringify(myHandshake));

      const theirLine = await channel.readLine();
      if (theirLine === null) return null;

      let theirHandshake: HandshakeMessage;
      try {
        theirHandshake = JSON.parse(theirLine) as HandshakeMessage;
      } catch (e) {
        return null;
      }
      if (!theirHandshake.EphemeralPublicKey || !theirHandshake.IdentityPublicKey || !theirHandshake.Signature) {
        return null;
      }

      if (!(await trustStore.isTrusted(context, theirHandshake.IdentityPublicKey))) {
        return null; // not a device we trust - refuse the connection outright
      }

      let theirEphemeralPubBytes: Uint8Array;
      let theirSignature: Uint8Array;
      try {
        theirEphemeralPubBytes = base64Helper.decodeSync(theirHandshake.EphemeralPublicKey);
        theirSignature = base64Helper.decodeSync(theirHandshake.Signature);
      } catch (e) {
        return null;
      }

      const verified = await verifyRawSignature(theirHandshake.IdentityPublicKey, theirEphemeralPubBytes, theirSignature);
      if (!verified) return null;

      const theirEphemeralKeyGen = cryptoFramework.createAsyKeyGenerator('ECC256');
      const theirEphemeralKeyPair = await theirEphemeralKeyGen.convertKey({ data: theirEphemeralPubBytes }, null);
      const keyAgreement = cryptoFramework.createKeyAgreement('ECC256');
      const sharedSecret = await keyAgreement.generateSecret(ephemeralKeyPair.priKey, theirEphemeralKeyPair.pubKey);
      // Matches .NET's ecdh.DeriveKeyFromHash(theirPublicKey, SHA256) with
      // no secretPrepend/secretAppend - that's just SHA256(rawSharedSecret).
      const sessionKey = await sha256(sharedSecret.data);

      return new PeerConnection(channel, sessionKey, theirHandshake.IdentityPublicKey);
    } catch (e) {
      return null;
    }
  }

  async send(message: string): Promise<void> {
    const encrypted = await AesGcm.encrypt(this.sessionKey, message);
    await this.channel.writeLine(encrypted);
  }

  onMessage(callback: (message: string) => void): void {
    this.messageCallback = callback;
  }

  onDisconnected(callback: () => void): void {
    this.disconnectedCallback = callback;
  }

  // Starts the read loop - fire-and-forget, matches PeerConnection.cs's
  // Listen() being kicked off without awaiting it. ANY failure (clean
  // close, corrupt/forged line that fails to decrypt) ends the whole
  // connection, same as the Windows side's single catch-all.
  listen(): void {
    void this.listenLoop();
  }

  private async listenLoop(): Promise<void> {
    try {
      while (true) {
        const line = await this.channel.readLine();
        if (line === null) break;
        const decrypted = await AesGcm.decrypt(this.sessionKey, line);
        this.messageCallback?.(decrypted);
      }
    } catch (e) {
      // abrupt disconnect, or a corrupt/forged line that failed to decrypt
    } finally {
      this.disconnectedCallback?.();
    }
  }

  close(): void {
    this.channel.close();
  }
}
