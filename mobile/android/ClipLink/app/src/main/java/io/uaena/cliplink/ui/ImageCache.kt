package io.uaena.cliplink.ui

import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import io.uaena.cliplink.core.B64
import java.io.File

/**
 * Decoded bitmaps, kept behind a size-bounded cache.
 *
 * Image entries carry their PNG inline as base64, so a list of them would
 * otherwise re-decode several megabytes on every recomposition and every
 * scroll. The cache is measured in bytes rather than entries because one
 * screenshot can outweigh twenty small images.
 */
object ImageCache {

    private val cache = object : LruCache<String, ImageBitmap>(BUDGET_BYTES) {
        override fun sizeOf(key: String, value: ImageBitmap): Int =
            value.width * value.height * 4
    }

    fun fromBase64(key: String, base64: String, maxDimension: Int): ImageBitmap? {
        val cacheKey = "$key@$maxDimension"
        cache.get(cacheKey)?.let { return it }
        val bytes = B64.decodeOrNull(base64) ?: return null
        val decoded = decode({ options -> BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) }, maxDimension)
            ?: return null
        cache.put(cacheKey, decoded)
        return decoded
    }

    fun fromFile(file: File, maxDimension: Int): ImageBitmap? {
        val cacheKey = "${file.absolutePath}@$maxDimension"
        cache.get(cacheKey)?.let { return it }
        if (!file.exists()) return null
        val decoded = decode({ options -> BitmapFactory.decodeFile(file.absolutePath, options) }, maxDimension)
            ?: return null
        cache.put(cacheKey, decoded)
        return decoded
    }

    /**
     * Two passes: the first measures without allocating, the second decodes
     * subsampled. Decoding a full-resolution screenshot to draw it at thumbnail
     * size is the quickest way to an OutOfMemoryError in a list.
     */
    private fun decode(
        decoder: (BitmapFactory.Options) -> android.graphics.Bitmap?,
        maxDimension: Int,
    ): ImageBitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            decoder(bounds)
            val width = bounds.outWidth
            val height = bounds.outHeight
            if (width <= 0 || height <= 0) return null
            var sample = 1
            while (width / sample > maxDimension || height / sample > maxDimension) sample *= 2
            val options = BitmapFactory.Options().apply { inSampleSize = sample }
            decoder(options)?.asImageBitmap()
        } catch (e: Throwable) {
            // OutOfMemoryError is an Error, not an Exception - a 40-megapixel
            // screenshot from a desktop peer is exactly the case that would
            // otherwise take the process down rather than show a placeholder.
            null
        }
    }

    private const val BUDGET_BYTES = 24 * 1024 * 1024
}
