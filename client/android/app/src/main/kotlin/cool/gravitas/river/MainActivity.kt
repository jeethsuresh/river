package cool.gravitas.river

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
