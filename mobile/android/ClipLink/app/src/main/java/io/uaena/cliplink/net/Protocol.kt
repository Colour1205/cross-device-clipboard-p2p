package io.uaena.cliplink.net

import org.json.JSONObject

/**
 * Wire message shapes. Every field name here is PascalCase because that is
 * what System.Text.Json produces on the Windows daemon with its default
 * settings, and all three implementations parse each other's JSON literally.
 * Renaming one to idiomatic Kotlin camelCase breaks interop silently: the
 * field just reads back as absent.
 */
object Protocol {
    const val TCP_PORT = 49000
    const val UDP_PORT = 49000

    const val TYPE_ENTRY = "entry"
    const val TYPE_HISTORY_BATCH = "history_batch"
    const val TYPE_FILE_CHUNK = "file_chunk"
    const val TYPE_FILE_REQUEST = "file_request"

    fun envelope(type: String, payload: String): String =
        JSONObject().apply {
            put("Type", type)
            put("Payload", payload)
        }.toString()
}

/** `{Type, Payload}` - Payload is itself a JSON *string*, not a nested object. */
data class Envelope(val type: String, val payload: String) {
    companion object {
        fun parse(json: String): Envelope? = try {
            val obj = JSONObject(json)
            val type = obj.optString("Type", "")
            if (type.isEmpty()) null else Envelope(type, obj.optString("Payload", ""))
        } catch (e: Exception) {
            null
        }
    }
}

/** What `ClipboardEntry.Content` holds when `Type == "file"` - a descriptor, never bytes. */
data class FilePayload(
    val fileName: String,
    val fileHash: String,
    val fileSize: Long,
) {
    fun toJson(): String = JSONObject().apply {
        put("FileName", fileName)
        put("FileHash", fileHash)
        put("FileSize", fileSize)
    }.toString()

    companion object {
        fun parse(json: String): FilePayload? = try {
            val obj = JSONObject(json)
            val hash = obj.optString("FileHash", "")
            if (hash.isEmpty()) {
                null
            } else {
                FilePayload(
                    fileName = obj.optString("FileName", "file"),
                    fileHash = hash,
                    fileSize = obj.optLong("FileSize", 0L),
                )
            }
        } catch (e: Exception) {
            null
        }
    }
}

data class FileChunkMessage(
    val fileHash: String,
    val chunkIndex: Int,
    val isLast: Boolean,
    val dataBase64: String,
) {
    fun toJson(): String = JSONObject().apply {
        put("FileHash", fileHash)
        put("ChunkIndex", chunkIndex)
        put("IsLast", isLast)
        put("DataBase64", dataBase64)
    }.toString()

    companion object {
        fun parse(json: String): FileChunkMessage? = try {
            val obj = JSONObject(json)
            val hash = obj.optString("FileHash", "")
            if (hash.isEmpty()) {
                null
            } else {
                FileChunkMessage(
                    fileHash = hash,
                    chunkIndex = obj.optInt("ChunkIndex", 0),
                    isLast = obj.optBoolean("IsLast", false),
                    dataBase64 = obj.optString("DataBase64", ""),
                )
            }
        } catch (e: Exception) {
            null
        }
    }
}

/** "Does anyone have this file?" - broadcast to every peer, never just the sender. */
data class FileRequestMessage(val fileHash: String) {
    fun toJson(): String = JSONObject().apply { put("FileHash", fileHash) }.toString()

    companion object {
        fun parse(json: String): FileRequestMessage? = try {
            JSONObject(json).optString("FileHash", "")
                .takeIf { it.isNotEmpty() }
                ?.let(::FileRequestMessage)
        } catch (e: Exception) {
            null
        }
    }
}

/**
 * The one unencrypted line each side writes before anything else. Both sides
 * write first and then read - there is no client/server role in the
 * handshake.
 */
data class HandshakeMessage(
    val ephemeralPublicKey: String,
    val identityPublicKey: String,
    val signature: String,
    val passphraseProof: String?,
) {
    fun toJson(): String = JSONObject().apply {
        put("EphemeralPublicKey", ephemeralPublicKey)
        put("IdentityPublicKey", identityPublicKey)
        put("Signature", signature)
        passphraseProof?.let { put("PassphraseProof", it) }
    }.toString()

    companion object {
        fun parse(json: String): HandshakeMessage? = try {
            val obj = JSONObject(json)
            val ephemeral = obj.optString("EphemeralPublicKey", "")
            val identity = obj.optString("IdentityPublicKey", "")
            val signature = obj.optString("Signature", "")
            if (ephemeral.isEmpty() || identity.isEmpty() || signature.isEmpty()) {
                null
            } else {
                HandshakeMessage(
                    ephemeralPublicKey = ephemeral,
                    identityPublicKey = identity,
                    signature = signature,
                    passphraseProof = obj.optString("PassphraseProof", "").takeIf { it.isNotEmpty() },
                )
            }
        } catch (e: Exception) {
            null
        }
    }
}

/** What a QR code / manual pairing string carries. */
data class PairingInfo(val publicKey: String, val address: String?) {
    fun toJson(): String = JSONObject().apply {
        put("PublicKey", publicKey)
        address?.takeIf { it.isNotEmpty() }?.let { put("Address", it) }
    }.toString()

    companion object {
        /** Accepts the JSON payload, or a bare public key, matching the daemon's trust_device command. */
        fun parse(raw: String): PairingInfo? {
            val trimmed = raw.trim()
            if (trimmed.isEmpty()) return null
            return try {
                val obj = JSONObject(trimmed)
                val key = obj.optString("PublicKey", "")
                if (key.isEmpty()) {
                    null
                } else {
                    PairingInfo(key, obj.optString("Address", "").takeIf { it.isNotEmpty() })
                }
            } catch (e: Exception) {
                PairingInfo(trimmed, null)
            }
        }
    }
}
