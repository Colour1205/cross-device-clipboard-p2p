package io.uaena.cliplink.core

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * PBKDF2-HMAC-SHA256, built directly on the HMAC primitive rather than going
 * through `SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")`.
 *
 * That is not reinvention for its own sake. `PBEKeySpec` takes a `char[]`,
 * and how a provider turns those chars into the password BYTES that get MAC'd
 * is provider-specific (PKCS#5 vs PKCS#12 vs UTF-8 conventions differ, and
 * Android has shipped more than one provider for this). The Windows daemon
 * MACs `Encoding.UTF8.GetBytes(passphrase)`, full stop. Feeding the bytes in
 * directly makes that unambiguous instead of a bet - and a wrong bet here is
 * invisible: both devices derive a key just fine, they simply derive
 * DIFFERENT keys, so the passcode auto-trust quietly never matches and looks
 * like "the other device isn't broadcasting".
 *
 * Standard construction: DK = T_1 || T_2 ... ; T_i = U_1 xor ... xor U_c ;
 * U_1 = HMAC(P, S || INT_32_BE(i)) ; U_j = HMAC(P, U_{j-1}).
 */
object Pbkdf2 {
    private const val H_LEN = 32 // SHA-256 output

    fun deriveSha256(
        password: ByteArray,
        salt: ByteArray,
        iterations: Int,
        keyLengthBytes: Int,
    ): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        val key = SecretKeySpec(password, "HmacSHA256")
        val blockCount = (keyLengthBytes + H_LEN - 1) / H_LEN
        val derived = ByteArray(blockCount * H_LEN)

        for (blockIndex in 1..blockCount) {
            mac.init(key)
            mac.update(salt)
            mac.update(int32BE(blockIndex))
            var u = mac.doFinal()
            val t = u.copyOf()
            for (iteration in 2..iterations) {
                mac.init(key)
                u = mac.doFinal(u)
                for (i in t.indices) t[i] = (t[i].toInt() xor u[i].toInt()).toByte()
            }
            t.copyInto(derived, (blockIndex - 1) * H_LEN)
        }
        return derived.copyOfRange(0, keyLengthBytes)
    }

    private fun int32BE(n: Int) = byteArrayOf(
        (n ushr 24).toByte(),
        (n ushr 16).toByte(),
        (n ushr 8).toByte(),
        n.toByte(),
    )
}

/**
 * Constant-time comparison, same intent as `CryptographicOperations
 * .FixedTimeEquals` on the Windows side: proof verification must not leak how
 * many leading bytes matched.
 */
fun fixedTimeEquals(a: ByteArray, b: ByteArray): Boolean {
    if (a.size != b.size) return false
    var diff = 0
    for (i in a.indices) diff = diff or (a[i].toInt() xor b[i].toInt())
    return diff == 0
}
