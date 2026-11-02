package cool.gravitas.river

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper

open class MainActivity : FlutterActivity() {
    private var engineEvicted = false
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        return cache.get("river") ?: FlutterEngine(context.applicationContext).also { engine ->
            // Create lazily: receiving a background Store alert must not start Dart.
            cache.put("river", engine)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        }
    }
    override fun shouldDestroyEngineWithHost() = false
    override fun shouldRestoreAndSaveState() = false
    override fun detachFromFlutterEngine() {
        engineEvicted = true
        super.detachFromFlutterEngine()
        // Keep the Android task: finishing it would remove its bubble. Rebuild
        // the detached Flutter view only when this document is shown again.
    }
    private var notifications: MethodChannel? = null
    private var permissionReply: MethodChannel.Result? = null
    private fun notificationOpen(consume: Boolean = true): Map<String, String>? {
        if (intent?.action != StorePush.OPEN) return null
        val subject = intent.getStringExtra("subject") ?: return null
        val room = intent.getStringExtra("room_id") ?: return null
        if (consume) intent.action = null
        return mapOf("subject" to subject, "room_id" to room)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (notifications != null) notificationOpen(false)?.let { notifications?.invokeMethod("opened", it) }
    }
    override fun onResume() {
        super.onResume()
        if (engineEvicted) { engineEvicted = false; recreate(); return }
        // A cached engine already completed boot. Re-expanding a bubble must
        // route again even if another conversation used the engine meanwhile.
        if (this is BubbleActivity && intent.hasExtra("room_id")) intent.action = StorePush.OPEN
        notificationOpen(false)?.let { notifications?.invokeMethod("opened", it) }
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Android can keep two windows resumed in multi-window mode.
        if (hasFocus && engineEvicted) { engineEvicted = false; recreate() }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4202) {
            val enabled = StorePush.allowed(this)
            StorePush.enable(this, enabled)
            if (enabled) Thread { StorePush.prepare(applicationContext) }.start()
            permissionReply?.success(StorePush.status(this)); permissionReply = null
        }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        notifications = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cool.gravitas.river/notifications").also { channel ->
            channel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "bind" -> {
                            StorePush.bind(this, call.argument<String>("issuer"), call.argument<String>("subject"))
                            if (StorePush.status(this)["enabled"] == true) Thread { StorePush.prepare(applicationContext) }.start()
                            result.success(StorePush.status(this))
                        }
                        "clear" -> { StorePush.clear(this); result.success(null) }
                        "read" -> { call.argument<String>("room_id")?.let { StorePush.read(this, it) }; result.success(null) }
                        "takeOpen" -> result.success(notificationOpen())
                        "status" -> result.success(StorePush.status(this))
                        "bubbleSettings" -> {
                            if (Build.VERSION.SDK_INT >= 30) startActivity(Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_BUBBLE_SETTINGS)
                                .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName))
                            result.success(null)
                        }
                        "enable" -> {
                            val enabled = call.argument<Boolean>("enabled") == true
                            if (enabled && Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                                if (permissionReply != null) { result.error("permission_pending", "Notification permission is already open.", null); return@setMethodCallHandler }
                                permissionReply = result
                                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 4202)
                            } else {
                                StorePush.enable(this, enabled)
                                if (enabled) Thread { StorePush.prepare(applicationContext) }.start()
                                result.success(StorePush.status(this))
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) { result.error("notifications", "Unable to update notifications.", null) }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cool.gravitas.river/auth")
            .setMethodCallHandler { call, result ->
                if (call.method != "broker") { result.notImplemented(); return@setMethodCallHandler }
                val challenge = call.argument<String>("challenge").orEmpty()
                val state = call.argument<String>("state").orEmpty()
                val username = call.argument<String>("username")
                Thread {
                    val reply = GravitasBroker(AndroidBrokerPlatform(applicationContext)).authorize(challenge, state, username)
                    Handler(Looper.getMainLooper()).post { result.success(reply) }
                }.start()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cool.gravitas.river/call")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            if (RiverCallService.onReady != null) {
                                result.error("call_service", "A call service change is already in progress.", null)
                                return@setMethodCallHandler
                            }
                            val handler = Handler(Looper.getMainLooper())
                            val timeout = Runnable {
                                RiverCallService.onReady = null
                                result.error("call_service", "Android did not start the call service in time.", null)
                            }
                            RiverCallService.onReady = { error ->
                                handler.removeCallbacks(timeout)
                                if (error == null) result.success(null)
                                else result.error("call_service", error, null)
                            }
                            handler.postDelayed(timeout, 5000)
                            val intent = Intent(this, RiverCallService::class.java)
                                .putExtra("camera", call.argument<Boolean>("camera") ?: false)
                                .putExtra("projection", call.argument<Boolean>("projection") ?: false)
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                        }
                        "stop" -> { stopService(Intent(this, RiverCallService::class.java)); result.success(null) }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    val callback = RiverCallService.onReady
                    RiverCallService.onReady = null
                    if (callback != null) callback("Android could not start the ongoing call service.")
                    else result.error("call_service", "Android could not start the ongoing call service.", null)
                }
            }
    }
}
