package io.uaena.cliplink.store

import android.content.Context
import io.uaena.cliplink.core.toHex
import java.io.File
import java.security.MessageDigest

/**
 * Content-addressed blob cache, keyed by lowercase SHA-256 hex. Mirrors
 * FileStore.cs / FileStore.ets.
 *
 * Descriptor-only by design: entry payloads carry a name/hash/size, never
 * bytes. The bytes arrive separately as chunk messages and land here.
 */
class FileStore(context: Context) {

    private val baseDir = File(context.applicationContext.filesDir, SUBDIR).apply { mkdirs() }

    /** Human-named copies for share sheets - a blob's own filename is its hash. */
    val sharedDir: File = File(context.applicationContext.cacheDir, "shared").apply { mkdirs() }

    fun path(hash: String): File = File(baseDir, hash)

    fun tempPath(hash: String): File = File(baseDir, "$hash.tmp")

    fun exists(hash: String): Boolean = path(hash).exists()

    fun delete(hash: String) {
        path(hash).delete()
    }

    fun write(hash: String, bytes: ByteArray) {
        path(hash).writeBytes(bytes)
    }

    companion object {
        private const val SUBDIR = "cliplink_files"
        private const val BUFFER = 256 * 1024

        fun hashOf(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

        /** Streams the file rather than reading it whole - these can be large. */
        fun hashOf(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { stream ->
                val buffer = ByteArray(BUFFER)
                while (true) {
                    val read = stream.read(buffer)
                    if (read <= 0) break
                    digest.update(buffer, 0, read)
                }
            }
            return digest.digest().toHex()
        }
    }
}
