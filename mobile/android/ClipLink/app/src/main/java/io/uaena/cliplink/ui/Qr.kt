package io.uaena.cliplink.ui

import android.graphics.Bitmap
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.MultiFormatWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

/**
 * Renders the pairing payload as a QR code.
 *
 * Drawn in monochrome on purpose: a device ID is a 124-character base64 SPKI,
 * so the payload sits near the high end of what a QR code carries comfortably
 * and any styling that softens module edges costs scan reliability.
 */
object Qr {
    fun encode(content: String, sizePx: Int, darkArgb: Int, lightArgb: Int): ImageBitmap? = try {
        val hints = mapOf(
            EncodeHintType.MARGIN to 1,
            EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M,
            EncodeHintType.CHARACTER_SET to "UTF-8",
        )
        val matrix = MultiFormatWriter()
            .encode(content, BarcodeFormat.QR_CODE, sizePx, sizePx, hints)
        val pixels = IntArray(matrix.width * matrix.height)
        for (y in 0 until matrix.height) {
            val row = y * matrix.width
            for (x in 0 until matrix.width) {
                pixels[row + x] = if (matrix.get(x, y)) darkArgb else lightArgb
            }
        }
        Bitmap.createBitmap(pixels, matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
            .asImageBitmap()
    } catch (e: Exception) {
        null
    }
}
