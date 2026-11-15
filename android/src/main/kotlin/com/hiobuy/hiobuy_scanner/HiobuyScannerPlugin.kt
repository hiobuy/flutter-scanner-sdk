package com.hiobuy.hiobuy_scanner

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class HiobuyScannerPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private val main = Handler(Looper.getMainLooper())
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var engine: ScannerEngine? = null
    private var sink: EventChannel.EventSink? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var hostLifecycle: Lifecycle? = null
    private var pendingPermission: MethodChannel.Result? = null

    private val hostObserver = object : DefaultLifecycleObserver {
        override fun onStart(owner: LifecycleOwner) {
            engine?.onHostStarted()
        }

        override fun onStop(owner: LifecycleOwner) {
            engine?.onHostStopped()
        }
    }

    // ---------------------------------------------------------- FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "hiobuy_scanner/methods")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "hiobuy_scanner/events")
        events.setStreamHandler(this)
        engine = ScannerEngine(context, binding.textureRegistry) { event ->
            // Events originate on worker threads; the sink is main-thread only.
            main.post { sink?.success(event) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        engine?.shutdown()
        engine = null
    }

    // ----------------------------------------------------------- ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        hostLifecycle = (binding.activity as? LifecycleOwner)?.lifecycle
        hostLifecycle?.addObserver(hostObserver)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        hostLifecycle?.removeObserver(hostObserver)
        hostLifecycle = null
        pendingPermission?.success(permission())
        pendingPermission = null
        engine?.stop()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        hostLifecycle?.removeObserver(hostObserver)
        hostLifecycle = null
    }

    // ----------------------------------------------------------- EventChannel

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // ---------------------------------------------------------- MethodChannel

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val t0 = SystemClock.elapsedRealtimeNanos()
        val engine = this.engine ?: return result.error("camera_error", "Plugin detached", null)
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
        try {
            when (call.method) {
                "getPermission" -> result.success(permission())
                "requestPermission" -> requestPermission(result)
                "openAppSettings" -> result.success(openAppSettings())
                "start" -> {
                    if (permission() != "granted") {
                        return result.error("permission_denied", "Camera permission not granted", null)
                    }
                    engine.start(EngineConfig(args), t0) { outcome ->
                        outcome.fold(
                            onSuccess = { result.success(it) },
                            onFailure = { e -> result.error((e as? EngineException)?.code ?: "camera_error", e.message, null) },
                        )
                    }
                }
                "stop" -> { engine.stop(); result.success(null) }
                "dispose" -> { engine.dispose(); result.success(null) }
                "pause" -> { engine.pause(args["level"] as? String ?: "results"); result.success(null) }
                "resume" -> { engine.resume(); result.success(null) }
                "updateConfig" -> result.success(engine.updateConfig(EngineConfig(args)))
                "setViewport" -> {
                    engine.setViewport(
                        (args["viewWidth"] as? Number)?.toDouble() ?: 0.0,
                        (args["viewHeight"] as? Number)?.toDouble() ?: 0.0,
                    )
                    result.success(null)
                }
                "setTorch" -> result.success(engine.setTorch(args["on"] as? Boolean ?: false))
                "focusAt" -> {
                    engine.focusAt(
                        (args["x"] as? Number)?.toDouble() ?: 0.5,
                        (args["y"] as? Number)?.toDouble() ?: 0.5,
                        (args["viewWidth"] as? Number)?.toDouble() ?: 0.0,
                        (args["viewHeight"] as? Number)?.toDouble() ?: 0.0,
                    )
                    result.success(null)
                }
                "resetDedupe" -> { engine.resetDedupe(); result.success(null) }
                "getStats" -> result.success(engine.stats())
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("camera_error", e.message ?: e.toString(), null)
        }
    }

    // -------------------------------------------------------------- permission

    private fun prefs() = context.getSharedPreferences("hiobuy_scanner", Context.MODE_PRIVATE)

    private fun permission(): String {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            return "granted"
        }
        val activity = activityBinding?.activity ?: return "denied"
        // Android does not say "never ask again" directly: it is the case where
        // we have asked before and the system no longer wants a rationale shown.
        val askedBefore = prefs().getBoolean(KEY_ASKED, false)
        val canAskAgain = ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.CAMERA)
        return if (askedBefore && !canAskAgain) "permanentlyDenied" else "denied"
    }

    private fun requestPermission(result: MethodChannel.Result) {
        val current = permission()
        val activity: Activity? = activityBinding?.activity
        if (current == "granted" || activity == null) return result.success(current)
        if (pendingPermission != null) return result.error("camera_error", "Permission request already in progress", null)
        pendingPermission = result
        ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.CAMERA), REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        prefs().edit().putBoolean(KEY_ASKED, true).apply()
        pendingPermission?.success(permission())
        pendingPermission = null
        return true
    }

    private fun openAppSettings(): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private companion object {
        const val REQUEST_CODE = 0x48B5
        const val KEY_ASKED = "camera_permission_asked"
    }
}
