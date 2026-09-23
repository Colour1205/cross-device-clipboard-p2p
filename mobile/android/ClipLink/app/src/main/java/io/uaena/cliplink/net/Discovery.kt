package io.uaena.cliplink.net

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress

/**
 * LAN peer discovery. Mirrors Discovery.cs and Discovery.ets exactly: same
 * port, same 2-second cadence, same beacon format
 * `{tcpPort}:{deviceId}:{proof}:{address}:{pairing}` with "-" for an absent
 * field. Device IDs are base64, which never contains ":", so splitting on it
 * is safe.
 */
class Discovery {

    data class Beacon(
        val tcpPort: Int,
        val deviceId: String,
        val proof: String?,
        val address: String?,
        /** True only while the sender's own pairing screen is open. */
        val pairing: Boolean,
        val senderIp: String,
    )

    private var socket: DatagramSocket? = null
    private var scope: CoroutineScope? = null

    var onPeer: ((Beacon) -> Unit)? = null
    var onError: ((String, Throwable) -> Unit)? = null

    val isRunning: Boolean get() = socket?.isClosed == false

    /**
     * [proof], [ownAddress] and [pairingOpen] are read fresh on every beacon,
     * not captured once. Each can change while running - a passcode set
     * later, a Tailscale IP typed in, the pairing screen opening - and must
     * take effect without a restart.
     */
    suspend fun start(
        deviceId: String,
        tcpPort: Int,
        proof: () -> String?,
        ownAddress: () -> String?,
        pairingOpen: () -> Boolean,
    ) = withContext(Dispatchers.IO) {
        stop()

        val udp = DatagramSocket(null).apply {
            reuseAddress = true
            broadcast = true
            bind(InetSocketAddress("0.0.0.0", Protocol.UDP_PORT))
        }
        socket = udp
        val discoveryScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        scope = discoveryScope

        discoveryScope.launch { receiveLoop(udp) }
        discoveryScope.launch { sendLoop(udp, deviceId, tcpPort, proof, ownAddress, pairingOpen) }
    }

    private suspend fun receiveLoop(udp: DatagramSocket) {
        val buffer = ByteArray(2048)
        while (currentCoroutineContext().isActive) {
            try {
                val packet = DatagramPacket(buffer, buffer.size)
                udp.receive(packet)
                val text = String(packet.data, packet.offset, packet.length, Charsets.UTF_8)
                parse(text, packet.address?.hostAddress ?: "")?.let { onPeer?.invoke(it) }
            } catch (e: Exception) {
                if (udp.isClosed) return
                // A transient receive error must not kill discovery for the
                // rest of the session. That exact failure mode - one throw,
                // socket never restarted, sync silently dead with nothing in
                // the log - is what the HarmonyOS port had to be fixed for.
                onError?.invoke("receive", e)
                delay(500)
            }
        }
    }

    private suspend fun sendLoop(
        udp: DatagramSocket,
        deviceId: String,
        tcpPort: Int,
        proof: () -> String?,
        ownAddress: () -> String?,
        pairingOpen: () -> Boolean,
    ) {
        val broadcast = InetAddress.getByName(BROADCAST_ADDRESS)
        var alreadyReported = false
        while (currentCoroutineContext().isActive) {
            try {
                val message = buildString {
                    append(tcpPort).append(':')
                    append(deviceId).append(':')
                    append(proof() ?: "-").append(':')
                    append(ownAddress() ?: "-").append(':')
                    append(if (pairingOpen()) "1" else "-")
                }
                val bytes = message.toByteArray(Charsets.UTF_8)
                udp.send(DatagramPacket(bytes, bytes.size, broadcast, Protocol.UDP_PORT))
                alreadyReported = false
            } catch (e: Exception) {
                if (udp.isClosed) return
                // On targetSdk 37 an EPERM here almost always means
                // ACCESS_LOCAL_NETWORK was denied, not that the network is
                // down. Reported once per failure streak so the log doesn't
                // fill with one line every two seconds.
                if (!alreadyReported) {
                    alreadyReported = true
                    onError?.invoke("send", e)
                }
            }
            delay(SEND_INTERVAL_MS)
        }
    }

    /**
     * Fully awaits the socket close AND the loops' cancellation. A caller
     * that stops and immediately restarts (which is what foregrounding does)
     * would otherwise race the release and get EADDRINUSE binding the same
     * fixed port again - and a failed rebind means no peer is discovered for
     * the rest of the session.
     */
    suspend fun stop() {
        val runningScope = scope
        scope = null
        val udp = socket
        socket = null
        udp?.close() // unblocks the receive() the loop is parked in
        runningScope?.coroutineContext?.get(Job)?.cancelAndJoin()
    }

    companion object {
        private const val BROADCAST_ADDRESS = "255.255.255.255"
        private const val SEND_INTERVAL_MS = 2000L

        fun parse(text: String, senderIp: String): Beacon? {
            val parts = text.split(':')
            if (parts.size < 3) return null // malformed or older-format beacon
            val port = parts[0].toIntOrNull() ?: return null
            if (parts[1].isEmpty()) return null
            return Beacon(
                tcpPort = port,
                deviceId = parts[1],
                proof = parts[2].takeIf { it != "-" && it.isNotEmpty() },
                address = parts.getOrNull(3)?.takeIf { it != "-" && it.isNotEmpty() },
                pairing = parts.getOrNull(4) == "1",
                senderIp = senderIp,
            )
        }
    }
}
