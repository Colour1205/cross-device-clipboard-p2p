package io.uaena.cliplink.engine

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.net.FilePayload
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** A history entry, plus everything the list needs that isn't on the wire. */
data class SyncedItem(
    val entry: ClipboardEntry,
    val isOwn: Boolean,
    val fileAvailable: Boolean,
) {
    val id: String get() = entry.key
    val type: String get() = entry.type

    val filePayload: FilePayload?
        get() = if (entry.type == ClipboardEntry.TYPE_FILE) FilePayload.parse(entry.content) else null

    /** "Link" is a display-only refinement of a text entry, never a wire type. */
    val isLink: Boolean
        get() = entry.type == ClipboardEntry.TYPE_TEXT && LINK_PATTERN.matches(entry.content.trim())

    val preview: String
        get() = when (entry.type) {
            ClipboardEntry.TYPE_TEXT -> entry.content
            ClipboardEntry.TYPE_IMAGE -> "Image"
            ClipboardEntry.TYPE_FILE -> filePayload?.fileName ?: "File"
            else -> entry.type
        }

    val timeLabel: String
        get() = runCatching {
            TIME_FORMAT.format(Instant.parse(entry.timestamp))
        }.getOrDefault("")

    private companion object {
        val LINK_PATTERN = Regex("^(https?|ftp)://\\S+$", RegexOption.IGNORE_CASE)
        val TIME_FORMAT: DateTimeFormatter =
            DateTimeFormatter.ofPattern("HH:mm:ss").withZone(ZoneId.systemDefault())
    }
}

/** One row in the Devices tab - a trusted device, a discovered one, or both. */
data class DeviceRow(
    val deviceId: String,
    val trusted: Boolean,
    val connected: Boolean,
    /** Every address this device is currently reachable at, LAN first. */
    val addresses: List<String>,
    /** The peer says its own pairing screen is open right now. */
    val pairing: Boolean,
    val lastSeenAtMs: Long?,
) {
    val shortId: String get() = deviceId.take(12)
}

data class LogLine(val time: String, val message: String)

/** A peer that completed a handshake but isn't trusted yet - awaiting an explicit decision. */
data class PairingRequest(val deviceId: String, val address: String?)
