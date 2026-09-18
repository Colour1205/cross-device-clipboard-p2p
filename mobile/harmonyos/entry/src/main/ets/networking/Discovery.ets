// Step 5 of the build order in ../../../../README.md: networking.
// Mirrors windows/daemon/Networking/Discovery.cs exactly — same port, same
// beacon format ("{tcpPort}:{deviceID}:{proof}:{address}:{pairing}", "-" for
// absent fields), same 2-second send interval. Device IDs are base64 (from
// DeviceIdentity.ets / DeviceIdentity.cs), which never contains ":", so
// splitting on ":" is safe.
//
// Whether LAN broadcast actually works without any extra permission beyond
// INTERNET was flagged as a genuine unknown in the step-2 spike, deferred
// here since it needs real socket code to test - this is that test.

import socket from '@ohos.net.socket';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

const PORT = 52388;
const BROADCAST_ADDRESS = '255.255.255.255';
const SEND_INTERVAL_MS = 2000;

export interface PeerBeacon {
  tcpPort: number;
  deviceId: string;
  proof: string | null;
  address: string | null;
  // True only while the sender's own Pairing screen is open - the signal
  // that makes it safe/expected to attempt a pairing handshake with an
  // otherwise-untrusted device found this way, instead of trying one with
  // every stranger's beacon on the LAN. See Index.ets's pairingOpen and
  // PeerConnection.create's pairingModeOpen gate.
  pairing: boolean;
  senderIp: string;
}

export class Discovery {
  private udp: socket.UDPSocket | null = null;
  private sendTimerId: number = -1;
  private peerCallback: ((beacon: PeerBeacon) => void) | null = null;
  private errorCallback: ((context: string, error: BusinessError) => void) | null = null;
  private decoder = util.TextDecoder.create('utf-8');

  onPeerDiscovered(callback: (beacon: PeerBeacon) => void): void {
    this.peerCallback = callback;
  }

  // Surfaced explicitly rather than swallowed - a bind/send failure here
  // (e.g. broadcast blocked) is itself a finding worth seeing, same lesson
  // as every other spike in this project so far.
  onError(callback: (context: string, error: BusinessError) => void): void {
    this.errorCallback = callback;
  }

  // getProof, getOwnAddress, and getPairingOpen are all called fresh on
  // every beacon, not just once at start - each can change live (a
  // passphrase set later, a manually-entered Tailscale IP, or the Pairing
  // screen opening/closing) and must take effect without a restart, same
  // reasoning as Discovery.cs's own getProof callback.
  async start(deviceId: string, tcpPort: number, getProof: () => string | null, getOwnAddress: () => string | null, getPairingOpen: () => boolean): Promise<void> {
    const udp = socket.constructUDPSocketInstance();
    this.udp = udp;

    udp.on('message', (info: socket.SocketMessageInfo) => {
      const text = this.decoder.decodeToString(new Uint8Array(info.message));
      const parts = text.split(':');
      if (parts.length < 3) return; // malformed/old-format beacon, ignore

      const beacon: PeerBeacon = {
        tcpPort: Number(parts[0]),
        deviceId: parts[1],
        proof: parts[2] === '-' ? null : parts[2],
        address: parts.length > 3 && parts[3] !== '-' ? parts[3] : null,
        pairing: parts.length > 4 && parts[4] === '1',
        senderIp: info.remoteInfo.address,
      };
      this.peerCallback?.(beacon);
    });

    try {
      await udp.bind({ address: '0.0.0.0', port: PORT });
      await udp.setExtraOptions({ broadcast: true });
    } catch (e) {
      this.errorCallback?.('bind/setExtraOptions', e as BusinessError);
      throw e as Error;
    }

    this.sendTimerId = setInterval(() => {
      const proof = getProof() ?? '-';
      const addr = getOwnAddress() ?? '-';
      const pairing = getPairingOpen() ? '1' : '-';
      const message = `${tcpPort}:${deviceId}:${proof}:${addr}:${pairing}`;
      udp.send({ data: message, address: { address: BROADCAST_ADDRESS, port: PORT } })
        .catch((e: BusinessError) => {
          this.errorCallback?.('send', e);
        });
    }, SEND_INTERVAL_MS);
  }

  stop(): void {
    if (this.sendTimerId !== -1) {
      clearInterval(this.sendTimerId);
      this.sendTimerId = -1;
    }
    this.udp?.close().catch(() => { /* already closed or never opened - fine */ });
    this.udp = null;
  }
}
