package cool.gravitas.river

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** One lazy engine owns the saved Matrix session. Opening River promotes this
 * same engine from background decryption to the app and its bubbles. */
internal object NotificationRuntime {
    private var channel: MethodChannel? = null
    private var ready = false
    private var foreground = false
    private val waiting = mutableListOf<() -> Unit>()
    fun engine(c: Context, show: Boolean = false): FlutterEngine {
        check(Looper.myLooper() == Looper.getMainLooper())
        foreground = foreground || show
        val cache = FlutterEngineCache.getInstance()
        val engine = cache.get("river") ?: FlutterEngine(c.applicationContext).also { engine ->
            cache.put("river", engine)
            channel = MethodChannel(engine.dartExecutor.binaryMessenger, "cool.gravitas.river/notification-runtime").also { ch ->
                ch.setMethodCallHandler { call, result ->
                    if (call.method != "ready") { result.notImplemented(); return@setMethodCallHandler }
                    ready = true
                    result.success(foreground)
                    waiting.toList().also { waiting.clear() }.forEach { it() }
                }
            }
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        }
        if (show && ready) channel?.invokeMethod("show", null)
        return engine
    }
    fun preview(c: Context, ticket: JSONObject, complete: (Map<*, *>?) -> Unit) {
        engine(c)
        var completed = false
        val handler = Handler(Looper.getMainLooper())
        fun finish(result: Map<*, *>?) {
            if (completed) return
            completed = true
            complete(result)
        }
        val deadline = Runnable { finish(null) }
        handler.postDelayed(deadline, 90_000)
        val invoke = invoke@{
            if (completed) return@invoke
            val args = ticket.keys().asSequence().associateWith { ticket.get(it) }
            channel!!.invokeMethod("preview", args, object : MethodChannel.Result {
                override fun success(result: Any?) { handler.removeCallbacks(deadline); finish(result as? Map<*, *>) }
                override fun error(code: String, message: String?, details: Any?) { handler.removeCallbacks(deadline); finish(null) }
                override fun notImplemented() { handler.removeCallbacks(deadline); finish(null) }
            })
        }
        if (ready) invoke() else waiting.add(invoke)
    }
}

/** JobScheduler grants background network execution. The pending queue contains
 * identifiers only, never decrypted text. */
class NotificationPreviewService : JobService() {
    private var current: JobParameters? = null
    private var busy = false
    override fun onStartJob(params: JobParameters): Boolean {
        running = this
        current = params
        drain()
        return true
    }
    private fun drain() {
        if (busy || current == null) return
        val ticket = StorePush.pending(this).firstOrNull()
        if (ticket == null) {
            val params = current ?: return
            current = null
            jobFinished(params, false)
            return
        }
        busy = true
        NotificationRuntime.preview(this, ticket) { result ->
            // A stopped job may still finish saving refreshed SDK credentials.
            // Native account/sequence guards decide if it can update an alert.
            StorePush.enrich(this, ticket, result)
            StorePush.finishPreview(this, ticket)
            busy = false
            if (current != null) drain() else if (StorePush.pending(this).isNotEmpty()) schedule(this)
        }
    }
    override fun onStopJob(params: JobParameters): Boolean {
        current = null
        return StorePush.pending(this).isNotEmpty()
    }
    override fun onDestroy() {
        if (running === this) running = null
        super.onDestroy()
    }
    companion object {
        private const val JOB = 4203
        private var running: NotificationPreviewService? = null
        fun schedule(c: Context) {
            val app = c.applicationContext
            Handler(Looper.getMainLooper()).post {
                val scheduler = app.getSystemService(JobScheduler::class.java)
                val service = running
                if (service?.current != null) { service.drain(); return@post }
                // jobFinished is delivered asynchronously to the scheduler.
                // A live service with no current job must replace that stale
                // pending record so an arrival during completion is not lost.
                if (service == null && scheduler.getPendingJob(JOB) != null) return@post
                val builder = JobInfo.Builder(JOB, ComponentName(app, NotificationPreviewService::class.java))
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                try {
                    if (Build.VERSION.SDK_INT >= 31) builder.setExpedited(true)
                    if (scheduler.schedule(builder.build()) == JobScheduler.RESULT_SUCCESS) return@post
                } catch (_: RuntimeException) { /* Quota/vendor fallback. */ }
                if (Build.VERSION.SDK_INT >= 31) builder.setExpedited(false)
                try { scheduler.schedule(builder.build()) } catch (_: RuntimeException) { }
            }
        }
    }
}
