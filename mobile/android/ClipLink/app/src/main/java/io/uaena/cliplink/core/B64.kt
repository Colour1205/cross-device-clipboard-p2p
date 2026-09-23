package io.uaena.cliplink.core

import android.util.Base64

/**
 * Base64 for everything that crosses the wire.
 *
 * NO_WRAP is not a style preference, it is correctness. [Base64.DEFAULT]
 * inserts a line break every 76 characters, and every single place this app
 * base64-encodes something is a place where a newline is catastrophic:
 *  - the UDP beacon is a colon-delimited single line,
 *  - the TCP session is newline-delimited framing, so an embedded `\n`
 *    splits one encrypted message into two undecryptable halves,
 *  - a device ID is a 124-character base64 SPKI, well past 76.
 *
 * NO_PADDING is deliberately NOT set - .NET's Convert.ToBase64String always
 * pads, and a device ID is compared as a raw string against what Windows and
 * HarmonyOS produce.
 */
object B64 {
    fun encode(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)

    fun decode(text: String): ByteArray = Base64.decode(text, Base64.NO_WRAP)

    /** Returns null instead of throwing, for anything a hostile peer supplied. */
    fun decodeOrNull(text: String?): ByteArray? {
        if (text.isNullOrEmpty()) return null
        return try {
            Base64.decode(text, Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            null
        }
    }
}

fun ByteArray.toHex(): String {
    val out = StringBuilder(size * 2)
    for (b in this) {
        val v = b.toInt() and 0xFF
        out.append("0123456789abcdef"[v ushr 4])
        out.append("0123456789abcdef"[v and 0x0F])
    }
    return out.toString()
}
