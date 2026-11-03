package cool.gravitas.river

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Build
import android.os.Bundle
import org.json.JSONObject
import java.security.MessageDigest

/** Authenticated Binder receiver. Render immediately, then schedule local decryption. */
class StoreNotifications : ContentProvider() {
    override fun onCreate() = true
    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val c = requireNotNull(context)
        if (method != "notify" || arg != null || !StorePush.trusted(c, Binder.getCallingUid())) throw SecurityException("Untrusted notification provider")
        val accepted = Bundle().apply { putBoolean("accepted", true) }
        val raw = extras?.getString("payload") ?: return accepted
        val identity = Binder.clearCallingIdentity()
        try { StorePush.deliver(c, raw) }
        catch (_: org.json.JSONException) { /* Discard malformed frames, allow later delivery. */ }
        catch (_: IllegalArgumentException) { }
        finally { Binder.restoreCallingIdentity(identity) }
        return accepted
    }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = throw UnsupportedOperationException()
    override fun getType(uri: Uri): String? = throw UnsupportedOperationException()
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
}

internal object StorePush {
    const val CHANNEL = "river-messages"
    const val OPEN = "cool.gravitas.river.OPEN_NOTIFICATION"
    private fun prefs(c: Context) = c.getSharedPreferences("river.push", Context.MODE_PRIVATE)
    // flutter_secure_storage 10.3.4's pinned default Android namespace. Compare
    // ciphertext only: no bearer is decrypted or copied into this cache.
    fun fingerprint(c: Context): String? {
        val encrypted = c.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE)
            .getString("VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_river_session", null) ?: return null
        return digest(encrypted.toByteArray())
    }
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    @Suppress("DEPRECATION")
    fun trusted(c: Context, uid: Int? = null): Boolean = try {
        val pm = c.packageManager
        val info = pm.getPackageInfo(BrokerProtocol.PACKAGE, if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)
        val signers = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        (uid == null || pm.getPackagesForUid(uid)?.toList() == listOf(BrokerProtocol.PACKAGE)) &&
            info.applicationInfo?.enabled == true && signers?.size == 1 && digest(signers[0].toByteArray()) == BrokerProtocol.CERTIFICATE
    } catch (_: Exception) { false }

    @Synchronized fun bind(c: Context, issuer: String?, subject: String?) {
        if (issuer != BrokerProtocol.ISSUER || subject.isNullOrBlank() || fingerprint(c) == null) { clear(c); return }
        if (prefs(c).getString("subject", null) != subject) clear(c)
        check(prefs(c).edit().putString("subject", subject).putString("session", fingerprint(c)).commit())
    }
    @Synchronized fun clear(c: Context) {
        c.getSystemService(NotificationManager::class.java).activeNotifications.filter { it.tag?.startsWith("river:") == true }.forEach { c.getSystemService(NotificationManager::class.java).cancel(it.tag, it.id) }
        ConversationBubbles.clear(c)
        // Preserve only this device's explicit per-account opt-in.
        val editor = prefs(c).edit()
        prefs(c).all.keys.filter { !it.startsWith("enabled:") }.forEach { editor.remove(it) }
        check(editor.commit())
    }
    fun allowed(c: Context): Boolean {
        val manager = c.getSystemService(NotificationManager::class.java)
        return (Build.VERSION.SDK_INT < 33 || c.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            manager.areNotificationsEnabled() && (Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)
    }
    fun status(c: Context): Map<String, Any> = mapOf("enabled" to (prefs(c).getBoolean("enabled:${prefs(c).getString("subject", "")}", false) && allowed(c)), "storeInstalled" to trusted(c), "bubblesSupported" to (Build.VERSION.SDK_INT >= 30))
    @Synchronized fun enable(c: Context, value: Boolean) {
        val subject = prefs(c).getString("subject", null) ?: return
        check(prefs(c).edit().putBoolean("enabled:$subject", value).commit())
        if (!value) {
            val editor = prefs(c).edit()
            prefs(c).all.keys.filter { it.startsWith("pending:") }.forEach { editor.remove(it) }
            check(editor.commit())
            c.getSystemService(NotificationManager::class.java).activeNotifications.filter { it.tag?.startsWith("river:") == true }.forEach { c.getSystemService(NotificationManager::class.java).cancel(it.tag, it.id) }
        }
    }
    fun prepare(c: Context) {
        if (!trusted(c)) return
        try {
            val authority = BrokerProtocol.PACKAGE + ".notifications"
            if (c.packageManager.resolveContentProvider(authority, 0)?.packageName != BrokerProtocol.PACKAGE) return
            c.contentResolver.call(Uri.parse("content://$authority"), "prepare", null, null)
        } catch (_: Exception) { /* Optional distributor; chat remains available. */ }
    }
    @Synchronized fun read(c: Context, room: String) {
        check(prefs(c).edit().remove("pending:" + digest(room.toByteArray())).commit())
        val manager = c.getSystemService(NotificationManager::class.java)
        val tag = "river:room:" + digest(room.toByteArray())
        val notification = manager.activeNotifications.firstOrNull { it.tag == tag && it.id == 1 }
        // Cancelling a bubbled notification closes the chat window itself.
        if (Build.VERSION.SDK_INT >= 30 && notification != null &&
            notification.notification.flags and Notification.FLAG_BUBBLE != 0) return
        manager.cancel(tag, 1)
    }
    @Synchronized fun deliver(c: Context, raw: String) {
        require(raw.toByteArray().size <= 8192)
        val payload = JSONObject(raw)
        val issuer = payload.getString("issuer"); val subject = payload.getString("subject")
        val room = payload.getString("room_id"); val event = payload.getString("event_id"); val sequence = payload.getLong("sequence")
        require(payload.getString("kind") == "matrix.event" && issuer == BrokerProtocol.ISSUER)
        require(room.startsWith("!") && room.length in 3..512 && event.startsWith("$") && event.length in 2..512 && sequence > 0)
        val p = prefs(c)
        if (p.getString("subject", null) != subject || !p.getBoolean("enabled:$subject", false) ||
            fingerprint(c).let { it == null || it != p.getString("session", null) } || !allowed(c)) return
        val key = "room:" + digest(room.toByteArray())
        if (p.getLong(key, 0) >= sequence) return
        val manager = c.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(CHANNEL, "Messages & invitations", NotificationManager.IMPORTANCE_DEFAULT))
        val intent = Intent(c, MainActivity::class.java).setAction(OPEN)
            .setData(Uri.parse("river://notification/" + digest(room.toByteArray())))
            .putExtra("subject", subject).putExtra("room_id", room).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val open = PendingIntent.getActivity(c, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(c, CHANNEL) else Notification.Builder(c)
        builder.setSmallIcon(R.drawable.ic_notification).setContentTitle("River")
            .setContentText("New conversation activity").setContentIntent(open).setAutoCancel(true).setOnlyAlertOnce(false)
            .setCategory(Notification.CATEGORY_MESSAGE).setVisibility(Notification.VISIBILITY_PRIVATE)
        ConversationBubbles.decorate(c, builder, subject, room)
        manager.notify("river:$key", 1, builder.build())
        val pendingKey = "pending:" + digest(room.toByteArray())
        val ticket = JSONObject().put("subject", subject).put("room_id", room).put("event_id", event)
            .put("sequence", sequence).put("session", fingerprint(c)).put("nonce", java.util.UUID.randomUUID().toString())
            .put("created", System.currentTimeMillis())
        val editor = p.edit().putLong(key, sequence).putString(pendingKey, ticket.toString())
        p.all.keys.filter { it.startsWith("pending:") && it != pendingKey }.drop(63).forEach { editor.remove(it) }
        if (p.all.size >= 1024) p.all.keys.filter { it.startsWith("room:") && it != key }.take(128).forEach { editor.remove(it) }
        check(editor.commit())
        NotificationPreviewService.schedule(c)
    }

    @Synchronized fun pending(c: Context): List<JSONObject> {
        val p = prefs(c); val session = fingerprint(c); val now = System.currentTimeMillis()
        val editor = p.edit()
        val tickets = p.all.filterKeys { it.startsWith("pending:") }.mapNotNull { (key, value) ->
            val ticket = try { JSONObject(value as String) } catch (_: Exception) { null }
            if (ticket != null && now - ticket.optLong("created") in 0..300_000 && session != null &&
                ticket.optString("session") == session && ticket.optString("subject") == p.getString("subject", null) &&
                p.getBoolean("enabled:${ticket.optString("subject")}", false)) ticket
            else { editor.remove(key); null }
        }
        check(editor.commit())
        return tickets.sortedByDescending { it.optLong("created") }
    }

    private fun pendingKey(ticket: JSONObject) = "pending:" + digest(ticket.getString("room_id").toByteArray())
    @Synchronized fun finishPreview(c: Context, ticket: JSONObject) {
        val key = pendingKey(ticket)
        val saved = prefs(c).getString(key, null) ?: return
        if (JSONObject(saved).optString("nonce") == ticket.optString("nonce")) check(prefs(c).edit().remove(key).commit())
    }
    @Synchronized fun enrich(c: Context, ticket: JSONObject, preview: Map<*, *>?) {
        if (preview == null) return
        val p = prefs(c)
        val saved = p.getString(pendingKey(ticket), null) ?: return
        val subject = ticket.getString("subject"); val room = ticket.getString("room_id")
        val age = System.currentTimeMillis() - ticket.optLong("created")
        if (JSONObject(saved).optString("nonce") != ticket.optString("nonce") || age !in 0..300_000 ||
            p.getString("subject", null) != subject || !p.getBoolean("enabled:$subject", false) ||
            ticket.getString("session") != fingerprint(c) || !allowed(c)) return
        val key = "room:" + digest(room.toByteArray())
        if (p.getLong(key, 0) != ticket.getLong("sequence")) return
        val manager = c.getSystemService(NotificationManager::class.java)
        val active = manager.activeNotifications.firstOrNull { it.tag == "river:$key" && it.id == 1 } ?: return
        fun text(key: String, limit: Int): String? = (preview[key] as? String)?.let {
            it.substring(0, it.offsetByCodePoints(0, minOf(limit, it.codePointCount(0, it.length))))
        }?.takeIf { it.isNotBlank() }
        val title = text("title", 160) ?: return
        val sender = text("sender", 160) ?: return
        val body = text("body", 500) ?: return
        val builder = Notification.Builder.recoverBuilder(c, active.notification)
            .setContentTitle(title).setContentText(body).setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion((if (Build.VERSION.SDK_INT >= 26) Notification.Builder(c, CHANNEL) else Notification.Builder(c))
                .setSmallIcon(R.drawable.ic_notification).setContentTitle("River").setContentText("New conversation activity").build())
        ConversationBubbles.decorate(c, builder, subject, room, title, sender, body)
        if (Build.VERSION.SDK_INT < 30) builder.setStyle(Notification.BigTextStyle().bigText("$sender: $body"))
        manager.notify("river:$key", 1, builder.build())
    }
}
