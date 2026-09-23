package io.uaena.cliplink.core

/**
 * ECDSA signature format conversion, P-256 only.
 *
 * The JCA (`Signature.getInstance("SHA256withECDSA")`) produces and expects
 * DER - an ASN.1 SEQUENCE of two INTEGERs. .NET's `ECDsa.SignData` produces
 * and expects raw fixed-width `r || s` (IEEE P1363), 64 bytes. The wire
 * format for this protocol is the .NET one, so every signature this app
 * produces must be converted on the way out and every signature it verifies
 * must be converted on the way in.
 *
 * Skipping this conversion does not fail loudly: `Signature.verify` just
 * returns false for a well-formed signature, which reads as "wrong key" or
 * "tampered entry" rather than "wrong encoding". The HarmonyOS port has the
 * identical layer (crypto/EcdsaDer.ets) for the same reason.
 */
object EcdsaDer {
    private const val FIELD_BYTES = 32

    /** DER SEQUENCE{INTEGER r, INTEGER s} -> raw r(32) || s(32). */
    fun derToRaw(der: ByteArray): ByteArray {
        require(der.size >= 8 && der[0] == 0x30.toByte()) {
            "not a DER ECDSA signature (missing SEQUENCE tag)"
        }
        var offset = 2 // SEQUENCE tag + short-form length; P-256 never needs long-form

        require(der[offset] == 0x02.toByte()) { "expected INTEGER tag for r" }
        offset++
        val rLen = der[offset].toInt() and 0xFF
        offset++
        val r = der.copyOfRange(offset, offset + rLen)
        offset += rLen

        require(der[offset] == 0x02.toByte()) { "expected INTEGER tag for s" }
        offset++
        val sLen = der[offset].toInt() and 0xFF
        offset++
        val s = der.copyOfRange(offset, offset + sLen)

        return toFixedWidth(r) + toFixedWidth(s)
    }

    /** raw r(32) || s(32) -> DER SEQUENCE{INTEGER r, INTEGER s}. */
    fun rawToDer(raw: ByteArray): ByteArray {
        require(raw.size == FIELD_BYTES * 2) {
            "expected a ${FIELD_BYTES * 2}-byte raw signature, got ${raw.size}"
        }
        val rInt = toDerInteger(raw.copyOfRange(0, FIELD_BYTES))
        val sInt = toDerInteger(raw.copyOfRange(FIELD_BYTES, raw.size))

        val content = byteArrayOf(0x02, rInt.size.toByte()) + rInt +
            byteArrayOf(0x02, sInt.size.toByte()) + sInt
        require(content.size < 128) { "DER length ${content.size} needs long-form encoding" }
        return byteArrayOf(0x30, content.size.toByte()) + content
    }

    /**
     * DER INTEGER content -> fixed width. Strips the single leading 0x00 DER
     * adds purely to keep a high-bit-set value positive, then left-pads with
     * zeros out to the field width.
     */
    private fun toFixedWidth(bytes: ByteArray): ByteArray {
        var start = 0
        if (bytes.size > FIELD_BYTES && bytes[0] == 0x00.toByte()) start = 1
        val trimmed = bytes.copyOfRange(start, bytes.size)
        require(trimmed.size <= FIELD_BYTES) {
            "DER integer too large for P-256 (${trimmed.size} bytes)"
        }
        val out = ByteArray(FIELD_BYTES)
        trimmed.copyInto(out, FIELD_BYTES - trimmed.size)
        return out
    }

    /**
     * Fixed width -> minimal DER INTEGER content: drop leading zeros, then
     * prepend 0x00 if the high bit is set (DER INTEGERs are signed, so
     * without it the value would decode as negative).
     */
    private fun toDerInteger(bytes: ByteArray): ByteArray {
        var start = 0
        while (start < bytes.size - 1 && bytes[start] == 0x00.toByte()) start++
        val trimmed = bytes.copyOfRange(start, bytes.size)
        return if (trimmed[0].toInt() and 0x80 != 0) byteArrayOf(0x00) + trimmed else trimmed
    }
}
