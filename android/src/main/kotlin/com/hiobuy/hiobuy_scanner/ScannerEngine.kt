package com.hiobuy.hiobuy_scanner

import android.content.Context
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Size
import android.view.Surface
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.ZoomSuggestionOptions
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import io.flutter.view.TextureRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class EngineException(val code: String, message: String) : Exception(message)

class EngineConfig(args: Map<*, *>) {
    val mode: ResultGate.Mode =
        if (args["mode"] == "single") ResultGate.Mode.SINGLE else ResultGate.Mode.CONTINUOUS
    val formats: List<String> =
        (args["formats"] as? List<*>)?.filterIsInstance<String>() ?: listOf("code128", "code39", "ean13", "ean8", "itf")
    val dedupeWindowMs: Double = (args["dedupeWindowMs"] as? Number)?.toDouble() ?: 1500.0

    /** Fractions of the Flutter view; null = whole view. */
    val region: Geometry.Box? = (args["region"] as? List<*>)?.let { r ->
        val n = r.filterIsInstance<Number>().map { it.toDouble() }
        if (n.size == 4) Geometry.Box(n[0], n[1], n[2], n[3]) else null
    }
    val vibrate: Boolean = args["vibrate"] as? Boolean ?: true
    val beep: Boolean = args["beep"] as? Boolean ?: false
    val resolution: String = args["resolution"] as? String ?: "hd720"
    val zoom: Double? = (args["zoom"] as? Number)?.toDouble()
    val autoZoom: Boolean = args["autoZoom"] as? Boolean ?: true
    val confirmations: Int = ((args["confirmations"] as? Number)?.toInt() ?: 2).coerceIn(1, 5)
    val labelHoldMs: Double = (args["labelHoldMs"] as? Number)?.toDouble() ?: 400.0

    /** Values fully matching one of these skip multi-frame confirmation. */
    private val fastAccept: List<Regex> =
        (args["fastAcceptPatterns"] as? List<*>)?.filterIsInstance<String>()?.mapNotNull {
            try { Regex(it) } catch (e: Exception) { null } // an invalid pattern is ignored
        } ?: emptyList()

    fun isFastAccepted(value: String): Boolean = fastAccept.any { it.matches(value) }
    val viewWidth: Double = (args["viewWidth"] as? Number)?.toDouble() ?: 0.0
    val viewHeight: Double = (args["viewHeight"] as? Number)?.toDouble() ?: 0.0

    val targetSize: Size
        get() = when (resolution) {
            "sd540" -> Size(960, 540)
            "fhd1080" -> Size(1920, 1080)
            else -> Size(1280, 720)
        }

    val mlKitFormats: IntArray
        get() {
            val out = ArrayList<Int>()
            for (f in formats) {
                when (f) {
                    "code128" -> out.add(Barcode.FORMAT_CODE_128)
                    "code39" -> out.add(Barcode.FORMAT_CODE_39)
                    // iOS reports UPC-A as EAN-13 with a leading 0; do the same here.
                    "ean13" -> { out.add(Barcode.FORMAT_EAN_13); out.add(Barcode.FORMAT_UPC_A) }
                    "ean8" -> out.add(Barcode.FORMAT_EAN_8)
                    "qr" -> out.add(Barcode.FORMAT_QR_CODE)
                    "itf" -> out.add(Barcode.FORMAT_ITF)
                }
            }
            return out.toIntArray()
        }
}

/**
 * Owns the CameraX pipeline.
 *
 * Threads:
 * - main: all CameraX binding and control calls, and every public method here.
 * - `analysisExecutor`: receives frames and hands them to ML Kit.
 * - `resultExecutor`: ML Kit callbacks → region filter → confirmation → gating.
 * - `feedbackExecutor`: vibration and beep, so neither delays the result.
 * State read off the main thread is volatile or atomic.
 *
 * [emit] may be called from any thread.
 */
class ScannerEngine(
    private val appContext: Context,
    private val textures: TextureRegistry,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private class EngineLifecycle : LifecycleOwner {
        val registry = LifecycleRegistry(this)
        override val lifecycle: Lifecycle get() = registry
    }

    private val main = Handler(Looper.getMainLooper())
    private val mainExecutor = ContextCompat.getMainExecutor(appContext)
    private var analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var resultExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val feedbackExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    // resultExecutor only: the value waiting for further frames to agree
    private var candidateValue: String? = null
    private var candidateCount = 0
    private var candidateLastNanos = 0L
    private var candidateFirstNanos = 0L
    private var candidateFirstAgeMs: Double? = null
    private val gate = ResultGate()

    // main thread only
    private var owner: EngineLifecycle? = null
    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var preview: Preview? = null
    private var analysis: ImageAnalysis? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var boundResolution: String? = null
    private var scannerKey: String? = null
    private var shouldRun = false
    private var hostStarted = true
    private var startGeneration = 0
    private var tone: ToneGenerator? = null // feedbackExecutor only
    private var autoZoomed = false
    private val resetZoom = Runnable {
        if (autoZoomed) {
            autoZoomed = false
            applyZoom(config)
        }
    }

    @Volatile private var config = EngineConfig(emptyMap<String, Any>())
    @Volatile private var scanner: BarcodeScanner? = null
    @Volatile private var pauseLevel: String? = null
    @Volatile private var viewWidth = 0.0
    @Volatile private var viewHeight = 0.0
    @Volatile private var startT0Nanos = 0L
    private val awaitingFirstFrame = AtomicBoolean(false)
    private val sequence = AtomicInteger()
    private val frames = AtomicInteger()
    private val detections = AtomicInteger()
    private val emitted = AtomicInteger()
    private val duplicates = AtomicInteger()
    private val outside = AtomicInteger()
    private val heldBack = AtomicInteger()
    private val fastAccepted = AtomicInteger()

    // ------------------------------------------------------------- lifecycle

    fun start(newConfig: EngineConfig, t0Nanos: Long, done: (Result<Map<String, Any?>>) -> Unit) {
        val generation = ++startGeneration
        val future = ProcessCameraProvider.getInstance(appContext)
        future.addListener({
            if (generation != startGeneration) {
                done(Result.failure(EngineException("camera_error", "Superseded by a later call")))
                return@addListener
            }
            try {
                provider = future.get()
                done(Result.success(bind(newConfig, t0Nanos)))
            } catch (e: EngineException) {
                shouldRun = false
                done(Result.failure(e))
            } catch (e: Exception) {
                shouldRun = false
                done(Result.failure(EngineException("camera_error", e.message ?: e.toString())))
            }
        }, mainExecutor)
    }

    private fun bind(newConfig: EngineConfig, t0Nanos: Long): Map<String, Any?> {
        val provider = this.provider ?: throw EngineException("camera_error", "Camera provider unavailable")
        if (!provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA)) {
            throw EngineException("camera_unavailable", "No back camera on this device")
        }
        val warm = camera != null && boundResolution == newConfig.resolution
        applyConfig(newConfig)
        gate.resetDedupe()
        gate.open()
        pauseLevel = null
        sequence.set(0); frames.set(0); detections.set(0); emitted.set(0); duplicates.set(0); outside.set(0); heldBack.set(0); fastAccepted.set(0)
        startT0Nanos = t0Nanos
        awaitingFirstFrame.set(true)
        shouldRun = true

        if (!warm) bindUseCases(provider, newConfig)
        ensureScanner(newConfig)
        analysis?.setAnalyzer(analysisExecutor, ::analyze)
        if (hostStarted) owner?.registry?.currentState = Lifecycle.State.STARTED
        applyZoom(newConfig)

        val info = preview?.resolutionInfo
        val result = HashMap<String, Any?>()
        result["warm"] = warm
        result["sessionReadyMs"] = (SystemClock.elapsedRealtimeNanos() - t0Nanos) / 1e6
        result["hasTorch"] = camera?.cameraInfo?.hasFlashUnit() ?: false
        result["textureId"] = textureEntry?.id()
        if (info != null) {
            val swap = info.rotationDegrees % 180 != 0
            result["previewWidth"] = (if (swap) info.resolution.height else info.resolution.width).toDouble()
            result["previewHeight"] = (if (swap) info.resolution.width else info.resolution.height).toDouble()
        }
        return result
    }

    private fun bindUseCases(provider: ProcessCameraProvider, cfg: EngineConfig) {
        provider.unbindAll()
        destroyOwner()
        val owner = EngineLifecycle().also { this.owner = it }
        owner.registry.currentState = Lifecycle.State.CREATED

        val selector = ResolutionSelector.Builder()
            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
            .setResolutionStrategy(
                ResolutionStrategy(cfg.targetSize, ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)
            )
            .build()

        val entry = textureEntry ?: textures.createSurfaceTexture().also { textureEntry = it }
        val preview = Preview.Builder().setResolutionSelector(selector).build()
        preview.setSurfaceProvider(mainExecutor) { request ->
            val texture = entry.surfaceTexture()
            texture.setDefaultBufferSize(request.resolution.width, request.resolution.height)
            val surface = Surface(texture)
            request.provideSurface(surface, mainExecutor) { surface.release() }
        }

        val analysis = ImageAnalysis.Builder()
            .setResolutionSelector(selector)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
            .build()

        val camera = try {
            provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
        } catch (e: Exception) {
            destroyOwner()
            throw EngineException("camera_error", e.message ?: "Cannot bind camera")
        }
        camera.cameraInfo.cameraState.observe(owner) { state -> onCameraState(state) }

        this.preview = preview
        this.analysis = analysis
        this.camera = camera
        this.boundResolution = cfg.resolution
    }

    /** Closes the camera but keeps use cases bound, so the next start is warm. */
    fun stop() {
        startGeneration++
        shouldRun = false
        gate.close()
        analysis?.clearAnalyzer()
        owner?.registry?.let { if (it.currentState.isAtLeast(Lifecycle.State.STARTED)) it.currentState = Lifecycle.State.CREATED }
    }

    fun dispose() {
        stop()
        provider?.unbindAll()
        destroyOwner()
        camera = null
        preview = null
        analysis = null
        boundResolution = null
        textureEntry?.release()
        textureEntry = null
        main.removeCallbacks(resetZoom)
        autoZoomed = false
        scanner?.close()
        scanner = null
        scannerKey = null
        feedbackExecutor.execute {
            tone?.release()
            tone = null
        }
    }

    /** Final teardown when the Flutter engine goes away. */
    fun shutdown() {
        dispose()
        analysisExecutor.shutdown()
        resultExecutor.shutdown()
        feedbackExecutor.shutdown()
    }

    private fun destroyOwner() {
        owner?.registry?.let {
            if (it.currentState.isAtLeast(Lifecycle.State.CREATED)) it.currentState = Lifecycle.State.DESTROYED
        }
        owner = null
    }

    fun pause(level: String) {
        gate.close()
        pauseLevel = level
        if (level == "analysis") analysis?.clearAnalyzer() else analysis?.setAnalyzer(analysisExecutor, ::analyze)
    }

    fun resume() {
        pauseLevel = null
        analysis?.setAnalyzer(analysisExecutor, ::analyze)
        gate.open()
    }

    /** Returns new preview info when the camera had to be rebound, else null. */
    fun updateConfig(newConfig: EngineConfig): Map<String, Any?>? {
        val old = config
        val modeChanged = old.mode != newConfig.mode
        if (shouldRun && camera != null && boundResolution != newConfig.resolution) {
            val provider = this.provider ?: return null
            applyConfig(newConfig)
            bindUseCases(provider, newConfig)
            ensureScanner(newConfig)
            if (pauseLevel != "analysis") analysis?.setAnalyzer(analysisExecutor, ::analyze)
            if (hostStarted) owner?.registry?.currentState = Lifecycle.State.STARTED
            applyZoom(newConfig)
            if (modeChanged && pauseLevel == null) gate.open()
            val info = preview?.resolutionInfo ?: return null
            val swap = info.rotationDegrees % 180 != 0
            return mapOf(
                "textureId" to textureEntry?.id(),
                "previewWidth" to (if (swap) info.resolution.height else info.resolution.width).toDouble(),
                "previewHeight" to (if (swap) info.resolution.width else info.resolution.height).toDouble(),
            )
        }
        applyConfig(newConfig)
        ensureScanner(newConfig)
        if (old.zoom != newConfig.zoom || old.autoZoom != newConfig.autoZoom) {
            main.removeCallbacks(resetZoom)
            autoZoomed = false
            applyZoom(newConfig)
        }
        if (modeChanged && pauseLevel == null) gate.open()
        return null
    }

    private fun applyConfig(cfg: EngineConfig) {
        config = cfg
        if (cfg.viewWidth > 0 && cfg.viewHeight > 0) {
            viewWidth = cfg.viewWidth
            viewHeight = cfg.viewHeight
        }
        gate.configure(cfg.mode, cfg.dedupeWindowMs, cfg.labelHoldMs)
    }

    /**
     * (Re)creates the ML Kit scanner when its options change. Auto-zoom needs
     * the bound camera's zoom range, so call this after binding.
     */
    private fun ensureScanner(cfg: EngineConfig) {
        val maxZoom = minOf(camera?.cameraInfo?.zoomState?.value?.maxZoomRatio ?: 1f, MAX_AUTO_ZOOM)
        val autoZoom = cfg.autoZoom && maxZoom > 1f
        val key = cfg.formats.joinToString(",") + "|" + (if (autoZoom) maxZoom else 0f)
        if (scanner != null && scannerKey == key) return
        val old = scanner
        val formats = cfg.mlKitFormats
        val options = BarcodeScannerOptions.Builder()
        if (formats.isNotEmpty()) {
            options.setBarcodeFormats(formats[0], *formats.copyOfRange(1, formats.size))
        }
        if (autoZoom) {
            // ML Kit calls this when it has located a barcode that is too small
            // to decode, with the zoom ratio that would make it readable.
            val callback = ZoomSuggestionOptions.ZoomCallback { ratio ->
                main.post { onZoomSuggested(ratio) }
                true
            }
            options.setZoomSuggestionOptions(
                ZoomSuggestionOptions.Builder(callback).setMaxSupportedZoomRatio(maxZoom).build()
            )
        }
        scanner = BarcodeScanning.getClient(options.build())
        scannerKey = key
        // Let a frame that is mid-decode on the old scanner finish first.
        if (old != null) resultExecutor.execute { old.close() }
    }

    private fun onZoomSuggested(ratio: Float) {
        val camera = this.camera ?: return
        if (!shouldRun || !config.autoZoom) return
        val state = camera.cameraInfo.zoomState.value
        val min = state?.minZoomRatio ?: 1f
        val max = minOf(state?.maxZoomRatio ?: 1f, MAX_AUTO_ZOOM)
        camera.cameraControl.setZoomRatio(ratio.coerceIn(min, max))
        autoZoomed = true
        scheduleZoomReset()
    }

    /** Zoom back out once nothing has needed the zoom for a moment. */
    private fun scheduleZoomReset() {
        main.removeCallbacks(resetZoom)
        main.postDelayed(resetZoom, ZOOM_RESET_DELAY_MS)
    }

    private fun applyZoom(cfg: EngineConfig) {
        val camera = this.camera ?: return
        val state = camera.cameraInfo.zoomState.value
        val min = state?.minZoomRatio ?: 1f
        val max = state?.maxZoomRatio ?: 1f
        camera.cameraControl.setZoomRatio((cfg.zoom?.toFloat() ?: 1f).coerceIn(min, max))
    }

    fun setViewport(width: Double, height: Double) {
        if (width > 0 && height > 0) {
            viewWidth = width
            viewHeight = height
        }
    }

    fun resetDedupe() = gate.resetDedupe()

    fun stats(): Map<String, Any?> = mapOf(
        "framesAnalyzed" to frames.get(),
        "detections" to detections.get(),
        "emitted" to emitted.get(),
        "duplicatesSuppressed" to duplicates.get(),
        "outsideRegion" to outside.get(),
        "heldBack" to heldBack.get(),
        "fastAccepted" to fastAccepted.get(),
    )

    // -------------------------------------------------------- host lifecycle

    /** The host activity went to the background: release the camera. */
    fun onHostStopped() {
        hostStarted = false
        if (!shouldRun) return
        owner?.registry?.let { if (it.currentState.isAtLeast(Lifecycle.State.STARTED)) it.currentState = Lifecycle.State.CREATED }
        emit(mapOf("type" to "state", "state" to "stopped", "reason" to "background"))
        emit(mapOf("type" to "torch", "on" to false))
    }

    /** Back in the foreground: reopen the camera if it was running. */
    fun onHostStarted() {
        hostStarted = true
        if (!shouldRun) return
        owner?.registry?.let { if (it.currentState == Lifecycle.State.CREATED) it.currentState = Lifecycle.State.STARTED }
        emitCurrentState()
    }

    private fun emitCurrentState() {
        val level = pauseLevel
        when {
            level != null -> emit(mapOf("type" to "state", "state" to "paused", "level" to level))
            // Single mode, still waiting for the business layer to resume.
            !gate.isAccepting -> emit(mapOf("type" to "state", "state" to "paused", "level" to "results"))
            else -> emit(mapOf("type" to "state", "state" to "running"))
        }
    }

    private fun onCameraState(state: CameraState) {
        val error = state.error ?: return
        val fatal = when (error.code) {
            CameraState.ERROR_CAMERA_DISABLED,
            CameraState.ERROR_CAMERA_FATAL_ERROR,
            CameraState.ERROR_DO_NOT_DISTURB_MODE_ENABLED -> true
            // In use by another app, too many cameras open, transient failure:
            // CameraX retries on its own.
            else -> false
        }
        emit(
            mapOf(
                "type" to "error",
                "code" to "camera_error",
                "fatal" to fatal,
                "message" to "CameraX error ${error.code}" + (error.cause?.message?.let { ": $it" } ?: ""),
            )
        )
    }

    // -------------------------------------------------------- camera control

    fun setTorch(on: Boolean): Boolean {
        val camera = this.camera ?: return false
        if (!camera.cameraInfo.hasFlashUnit()) return false
        camera.cameraControl.enableTorch(on)
        return on
    }

    /** [x], [y] are fractions of the Flutter view. */
    fun focusAt(x: Double, y: Double, viewW: Double, viewH: Double) {
        val camera = this.camera ?: return
        val info = preview?.resolutionInfo ?: return
        setViewport(viewW, viewH)
        val swap = info.rotationDegrees % 180 != 0
        val imageW = (if (swap) info.resolution.height else info.resolution.width).toDouble()
        val imageH = (if (swap) info.resolution.width else info.resolution.height).toDouble()
        val (u, v) = Geometry.viewToImage(x, y, viewWidth, viewHeight, imageW, imageH)
        val (sx, sy) = Geometry.uprightToSensor(u, v, info.rotationDegrees)
        val point = SurfaceOrientedMeteringPointFactory(1f, 1f).createPoint(sx.toFloat(), sy.toFloat())
        val action = FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE)
            .setAutoCancelDuration(3, TimeUnit.SECONDS) // then back to continuous autofocus
            .build()
        camera.cameraControl.startFocusAndMetering(action)
    }

    // -------------------------------------------------------------- analysis

    @androidx.annotation.OptIn(ExperimentalGetImage::class)
    private fun analyze(proxy: ImageProxy) {
        val tStart = SystemClock.elapsedRealtimeNanos()
        if (awaitingFirstFrame.compareAndSet(true, false)) {
            emit(mapOf("type" to "firstFrame", "sinceStartMs" to (tStart - startT0Nanos) / 1e6))
        }
        val image = proxy.image
        val scanner = this.scanner
        if (image == null || scanner == null) {
            proxy.close()
            return
        }
        val rotation = proxy.imageInfo.rotationDegrees
        val swap = rotation % 180 != 0
        val uprightW = (if (swap) proxy.height else proxy.width).toDouble()
        val uprightH = (if (swap) proxy.width else proxy.height).toDouble()
        val frameAgeMs = frameAgeMs(proxy.imageInfo.timestamp, tStart)
        frames.incrementAndGet()
        try {
            // Wraps the camera buffer directly: no copy, no format conversion.
            scanner.process(InputImage.fromMediaImage(image, rotation))
                .addOnSuccessListener(resultExecutor) { barcodes ->
                    if (barcodes.isNotEmpty()) onBarcodes(barcodes, uprightW, uprightH, tStart, frameAgeMs)
                }
                // Runs on success, failure and cancellation alike; the next frame
                // is only delivered once this one is closed.
                .addOnCompleteListener(resultExecutor) { proxy.close() }
        } catch (e: Exception) {
            proxy.close()
        }
    }

    /**
     * Sensor timestamps are on the elapsed-realtime clock on most devices and
     * on the uptime clock on some. Accept whichever gives a plausible age.
     */
    private fun frameAgeMs(frameTimestamp: Long, nowRealtimeNanos: Long): Double? {
        val a = (nowRealtimeNanos - frameTimestamp) / 1e6
        if (a >= 0 && a < 2000) return a
        val b = (System.nanoTime() - frameTimestamp) / 1e6
        if (b >= 0 && b < 2000) return b
        return null
    }

    private fun onBarcodes(barcodes: List<Barcode>, imageW: Double, imageH: Double, tStart: Long, frameAgeMs: Double?) {
        val cfg = config
        val region = cfg.region?.let { Geometry.viewToImage(it, viewWidth, viewHeight, imageW, imageH) } ?: Geometry.FULL

        var best: Barcode? = null
        var bestValue = ""
        var bestFormat = ""
        var bestBox: Geometry.Box? = null
        var bestDistance = Double.MAX_VALUE
        var anyOutside = false
        for (b in barcodes) {
            var value = b.rawValue ?: continue
            if (value.isEmpty()) continue
            val format = when (b.format) {
                Barcode.FORMAT_CODE_128 -> "code128"
                Barcode.FORMAT_CODE_39 -> "code39"
                Barcode.FORMAT_EAN_13 -> "ean13"
                Barcode.FORMAT_UPC_A -> { value = "0$value"; "ean13" }
                Barcode.FORMAT_EAN_8 -> "ean8"
                Barcode.FORMAT_QR_CODE -> "qr"
                Barcode.FORMAT_ITF -> "itf"
                else -> continue
            }
            val r = b.boundingBox
            val box = if (r != null) {
                Geometry.Box(r.left / imageW, r.top / imageH, r.right / imageW, r.bottom / imageH)
            } else null
            val cx = box?.centerX ?: 0.5
            val cy = box?.centerY ?: 0.5
            if (!region.contains(cx, cy)) {
                anyOutside = true
                continue
            }
            val dx = cx - region.centerX
            val dy = cy - region.centerY
            val distance = dx * dx + dy * dy
            if (distance < bestDistance) {
                bestDistance = distance
                best = b
                bestValue = value
                bestFormat = format
                bestBox = box
            }
        }
        if (best == null) {
            if (anyOutside) outside.incrementAndGet()
            return
        }

        detections.incrementAndGet()
        if (cfg.autoZoom) main.post { if (autoZoomed) scheduleZoomReset() }
        val now = SystemClock.elapsedRealtimeNanos()

        // Require consecutive frames to agree: a misread of a blurred or partly
        // visible barcode almost never decodes to the same garbage twice.
        var firstNanos = tStart
        var firstAgeMs = frameAgeMs
        val trusted = cfg.confirmations > 1 && cfg.isFastAccepted(bestValue)
        if (cfg.confirmations > 1 && !trusted) {
            if (bestValue == candidateValue && tStart - candidateLastNanos < CONFIRM_MAX_GAP_NANOS) {
                candidateCount++
            } else {
                candidateValue = bestValue
                candidateCount = 1
                candidateFirstNanos = tStart
                candidateFirstAgeMs = frameAgeMs
            }
            candidateLastNanos = tStart
            if (candidateCount < cfg.confirmations) return
            firstNanos = candidateFirstNanos
            firstAgeMs = candidateFirstAgeMs
        }

        when (gate.offer(bestValue, now / 1e6)) {
            ResultGate.Decision.DUPLICATE -> { duplicates.incrementAndGet(); return }
            ResultGate.Decision.HELD -> { heldBack.incrementAndGet(); return }
            ResultGate.Decision.CLOSED -> return
            ResultGate.Decision.EMIT -> Unit
        }
        emitted.incrementAndGet()
        if (trusted) fastAccepted.incrementAndGet()

        // Feedback is started at once but on its own thread: the vibrator and
        // tone calls can block for tens of milliseconds.
        if (cfg.vibrate || cfg.beep) {
            feedbackExecutor.execute {
                if (cfg.vibrate) vibrate()
                if (cfg.beep) beep()
            }
        }

        val sinceAnalysisMs = (now - tStart) / 1e6
        val event = HashMap<String, Any?>()
        event["type"] = "result"
        event["value"] = bestValue
        event["format"] = bestFormat
        event["platform"] = "android"
        event["sequence"] = sequence.incrementAndGet()
        event["emitEpochUs"] = System.currentTimeMillis() * 1000
        event["decodeMs"] = sinceAnalysisMs
        // Measured from the first agreeing frame, so the confirmation wait counts.
        event["frameAgeMs"] = firstAgeMs
        event["nativeTotalMs"] = firstAgeMs?.let { it + (now - firstNanos) / 1e6 }
        event["box"] = bestBox?.toList()
        emit(event)
    }

    // -------------------------------------------------------------- feedback

    private fun vibrate() {
        try {
            @Suppress("DEPRECATION")
            val vibrator = appContext.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
            if (Build.VERSION.SDK_INT >= 26) {
                vibrator.vibrate(VibrationEffect.createOneShot(40, VibrationEffect.DEFAULT_AMPLITUDE))
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(40)
            }
        } catch (e: Exception) {
            // Missing permission or no vibrator: feedback is best-effort.
        }
    }

    private companion object {
        /** Beyond this the image is too shaky to hold by hand. */
        const val MAX_AUTO_ZOOM = 5f
        const val ZOOM_RESET_DELAY_MS = 1500L

        /** Sightings further apart than this are not "consecutive". */
        const val CONFIRM_MAX_GAP_NANOS = 300_000_000L
    }

    private fun beep() {
        try {
            val t = tone ?: ToneGenerator(AudioManager.STREAM_MUSIC, 80).also { tone = it }
            t.startTone(ToneGenerator.TONE_PROP_BEEP, 80)
        } catch (e: Exception) {
            tone = null
        }
    }
}
