package cool.gravitas.river

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** Local Android-required ongoing-call indicator, not push or incoming-call delivery. */
class RiverCallService : Service() {
    companion object { var onReady: ((String?) -> Unit)? = null }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
        val channel = "river_ongoing_call"
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel(channel, "Ongoing River calls", NotificationManager.IMPORTANCE_LOW)
        )
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channel) else Notification.Builder(this)
        val notification = builder.setContentTitle("River call in progress")
            .setContentText("Tap to return to call controls")
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentIntent(open).setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL).build()
        if (Build.VERSION.SDK_INT >= 29) {
            var types = if (Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
            if (Build.VERSION.SDK_INT >= 30 && intent?.getBooleanExtra("camera", false) == true)
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            if (intent?.getBooleanExtra("projection", false) == true)
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            startForeground(4201, notification, types)
        } else startForeground(4201, notification)
            val callback = onReady; onReady = null; callback?.invoke(null)
        } catch (error: Exception) {
            val callback = onReady; onReady = null
            callback?.invoke("Android could not keep this call active. Check microphone and screen sharing permissions.")
            stopSelf()
        }
        return START_NOT_STICKY
    }
    override fun onTaskRemoved(rootIntent: Intent?) { stopSelf(); super.onTaskRemoved(rootIntent) }
    override fun onDestroy() { stopForeground(STOP_FOREGROUND_REMOVE); super.onDestroy() }
}
