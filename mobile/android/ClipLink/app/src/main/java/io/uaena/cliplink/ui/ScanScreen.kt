package io.uaena.cliplink.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.zxing.BinaryBitmap
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors

// Reused across frames rather than allocated per-frame - safe because
// analysis.setAnalyzer runs on a single-thread executor, so decodeQr is
// never called concurrently.
private val qrReader = MultiFormatReader()

/**
 * Camera-based QR scanner for pairing. Decodes via zxing-core (already a
 * dependency for QrPanel's own display side) rather than pulling in a
 * second barcode library - the only new piece here is feeding CameraX
 * frames into it.
 */
@Composable
fun ScanScreen(
    contentPadding: PaddingValues,
    onBack: () -> Unit,
    onResult: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    var hasPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted -> hasPermission = granted }

    Column(
        modifier
            .fillMaxSize()
            .padding(
                start = 16.dp,
                end = 16.dp,
                top = contentPadding.calculateTopPadding(),
                bottom = contentPadding.calculateBottomPadding() + 32.dp,
            ),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(top = 8.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
            }
            Spacer(Modifier.width(4.dp))
            Text(
                "Scan a device's code",
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }

        Spacer(Modifier.height(20.dp))

        if (hasPermission) {
            CameraPreview(onResult = onResult)
            Spacer(Modifier.height(16.dp))
            Text(
                "Point the camera at the other device's pairing code. Its own pairing screen " +
                    "has to be open too - a scan alone can't trust it.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            Surface(
                shape = RoundedCornerShape(28.dp),
                color = MaterialTheme.colorScheme.surfaceContainerLow,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(
                    Modifier.padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(
                        Icons.Filled.CameraAlt,
                        contentDescription = null,
                        modifier = Modifier.padding(bottom = 12.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        "Camera access is needed to scan a code.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Spacer(Modifier.height(16.dp))
                    Button(onClick = { permissionLauncher.launch(Manifest.permission.CAMERA) }) {
                        Text("Grant camera access")
                    }
                }
            }
        }
    }
}

@Composable
private fun CameraPreview(onResult: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    // rememberUpdatedState so the analyzer (set up once, in the
    // AndroidView factory below) always calls the LATEST onResult lambda,
    // not a stale one captured at first composition.
    val currentOnResult by rememberUpdatedState(onResult)
    // Guards against firing onResult more than once - frames keep arriving
    // (and keep decoding successfully) for as long as the camera stays
    // bound after a hit, and the caller only expects a single callback.
    var resultDelivered by remember { mutableStateOf(false) }
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    // bindToLifecycle ties the use cases to the ACTIVITY's lifecycle, not
    // to this composable's presence - ScanScreen gets unmounted via
    // ClipLinkApp's AnimatedContent (a plain state change), not an
    // Activity stop/start, so without explicitly unbinding here the
    // camera stays bound and streaming after the user backs out: held
    // hardware, drained battery, the camera-in-use indicator staying lit
    // until the screen happens to be reopened (whose factory unbinds
    // first) or the app backgrounds. Plain var, not remembered state -
    // this only exists for onDispose to reach into, never read during
    // composition.
    var boundCameraProvider: ProcessCameraProvider? = null

    DisposableEffect(Unit) {
        onDispose {
            analysisExecutor.shutdown()
            boundCameraProvider?.unbindAll()
        }
    }

    Surface(
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(RoundedCornerShape(24.dp)),
        ) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    val previewView = PreviewView(ctx)
                    val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
                    cameraProviderFuture.addListener({
                        val cameraProvider = cameraProviderFuture.get()
                        boundCameraProvider = cameraProvider

                        val preview = Preview.Builder().build().also {
                            it.surfaceProvider = previewView.surfaceProvider
                        }

                        val analysis = ImageAnalysis.Builder()
                            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                            .build()
                        analysis.setAnalyzer(analysisExecutor) { imageProxy ->
                            decodeQr(imageProxy)?.let { text ->
                                if (!resultDelivered) {
                                    resultDelivered = true
                                    currentOnResult(text)
                                }
                            }
                        }

                        try {
                            cameraProvider.unbindAll()
                            cameraProvider.bindToLifecycle(
                                lifecycleOwner,
                                CameraSelector.DEFAULT_BACK_CAMERA,
                                preview,
                                analysis,
                            )
                        } catch (e: Exception) {
                            // Camera already in use by another app, or this device
                            // genuinely has none - "Pair by address" below still works.
                        }
                    }, ContextCompat.getMainExecutor(ctx))
                    previewView
                },
            )
        }
    }
}

/**
 * Reads the Y (luma) plane straight out of the frame - QR decoding only
 * needs luminance, not full YUV_420_888 color conversion, which is what
 * makes this cheap enough to run on every frame from a single-thread
 * executor. Returns null (not just on a decode miss, which is the expected
 * common case every frame without a code in view, but also on any
 * unexpected error) - never throws out of an analyzer callback.
 */
private fun decodeQr(imageProxy: ImageProxy): String? {
    try {
        val plane = imageProxy.planes[0]
        val buffer = plane.buffer
        val bytes = ByteArray(buffer.remaining())
        buffer.get(bytes)

        // dataWidth has to be the Y-plane's actual ROW STRIDE, not the
        // image's pixel width - YUV_420_888 output is allowed to pad each
        // row (rowStride > width) on some devices/resolutions, and using
        // the unpadded width here would silently misalign every row past
        // the first, making the decoder essentially never find a real
        // code on any device that happens to pad. The crop rect below
        // (0, 0, width, height) is still the true image size - that's
        // what excludes the padding bytes from actually being scanned.
        val source = PlanarYUVLuminanceSource(
            bytes,
            plane.rowStride,
            imageProxy.height,
            0,
            0,
            imageProxy.width,
            imageProxy.height,
            false,
        )
        val bitmap = BinaryBitmap(HybridBinarizer(source))
        return qrReader.decode(bitmap).text
    } catch (e: NotFoundException) {
        return null // no QR code in this frame - the normal case
    } catch (e: Exception) {
        return null
    } finally {
        imageProxy.close()
    }
}
