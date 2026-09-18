// Step 5 of the build order in ../../../../README.md: networking.
// Raw TCP transport only - connectivity proof, nothing else. No
// encryption, no handshake, no framing beyond what's sent (that's step 6,
// mirroring PeerConnection.cs). Deliberately kept this thin so step 5 can
// be verified on-device (both listen and connect) before any protocol
// logic gets layered on top of unproven transport.

import socket from '@ohos.net.socket';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

const decoder = util.TextDecoder.create('utf-8');

export class TcpServer {
  private server: socket.TCPSocketServer | null = null;
  private connectionCallback: ((conn: socket.TCPSocketConnection) => void) | null = null;

  onConnection(callback: (conn: socket.TCPSocketConnection) => void): void {
    this.connectionCallback = callback;
  }

  async start(port: number): Promise<void> {
    const server = socket.constructTCPSocketServerInstance();
    this.server = server;
    server.on('connect', (conn: socket.TCPSocketConnection) => {
      this.connectionCallback?.(conn);
    });
    await server.listen({ address: '0.0.0.0', port });
  }

  stop(): void {
    this.server?.close().catch(() => { /* already closed or never started - fine */ });
    this.server = null;
  }
}

// Connects out to a peer and returns the raw socket - caller owns framing,
// sending, and closing from here. No timeout guard here yet deliberately
// mirrors the fact that PeerConnection.cs itself doesn't have one either
// (see docs/security.md finding #2) - not copying a known gap silently,
// just not fixing a Windows-side gap from the HarmonyOS side first.
export async function connectTcp(address: string, port: number, timeoutMs: number = 5000): Promise<socket.TCPSocket> {
  const client = socket.constructTCPSocketInstance();
  await client.connect({ address: { address, port }, timeout: timeoutMs });
  return client;
}

export function decodeMessage(message: ArrayBuffer): string {
  return decoder.decodeToString(new Uint8Array(message));
}
