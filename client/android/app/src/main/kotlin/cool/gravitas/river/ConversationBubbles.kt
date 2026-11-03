package cool.gravitas.river

import android.app.Notification
import android.app.PendingIntent
import android.app.Person
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import java.security.MessageDigest

/** Adds conversation UI using generic text or content decrypted on this device. */
internal object ConversationBubbles {
    private const val PREFIX = "river-conversation:"

    fun id(subject: String, room: String): String = PREFIX + MessageDigest.getInstance("SHA-256")
        .digest("$subject\u0000$room".toByteArray()).joinToString("") { "%02x".format(it) }

    fun intent(c: Context, subject: String, room: String): Intent =
        Intent(c, BubbleActivity::class.java).setAction(StorePush.OPEN)
            .setData(Uri.parse("river://conversation/" + id(subject, room).removePrefix(PREFIX)))
            .putExtra("subject", subject).putExtra("room_id", room)

    fun decorate(c: Context, builder: Notification.Builder, subject: String, room: String,
        title: String = "River conversation", sender: String = "Conversation", body: String = "New conversation activity") {
        // Android 11 introduced the user-facing conversation bubble controls.
        if (Build.VERSION.SDK_INT < 30) return
        val shortcutId = id(subject, room)
        val icon = Icon.createWithResource(c, R.drawable.ic_river)
        val person = Person.Builder().setName(sender).setKey(shortcutId).setIcon(icon).build()
        val shortcut = ShortcutInfo.Builder(c, shortcutId)
            .setActivity(ComponentName(c, MainActivity::class.java))
            .setShortLabel(title).setIcon(icon)
            .setIntent(intent(c, subject, room))
            .setLongLived(true).setPersons(arrayOf(person)).build()
        try {
            val manager = c.getSystemService(ShortcutManager::class.java)
            manager.pushDynamicShortcut(shortcut)
            manager.enableShortcuts(listOf(shortcutId))
        } catch (_: RuntimeException) {
            // Shortcut quotas, locked users, or vendor restrictions must never
            // prevent the underlying private notification from being delivered.
            return
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
        val open = PendingIntent.getActivity(c, 0, intent(c, subject, room), flags)
        builder.setStyle(Notification.MessagingStyle(Person.Builder().setName("You").build())
            .setConversationTitle(if (title == "River conversation") null else title)
            .setGroupConversation(title != "River conversation")
            .addMessage(body, System.currentTimeMillis(), person))
            .setShortcutId(shortcutId)
            .setBubbleMetadata(Notification.BubbleMetadata.Builder(open, icon).setDesiredHeight(640).build())
    }

    fun clear(c: Context) {
        if (Build.VERSION.SDK_INT < 30) return
        try {
            val manager = c.getSystemService(ShortcutManager::class.java)
            val shortcuts = manager.getShortcuts(ShortcutManager.FLAG_MATCH_DYNAMIC or
                ShortcutManager.FLAG_MATCH_CACHED or ShortcutManager.FLAG_MATCH_PINNED)
                .map { it.id }.filter { it.startsWith(PREFIX) }
            if (shortcuts.isNotEmpty()) {
                manager.disableShortcuts(shortcuts)
                manager.removeLongLivedShortcuts(shortcuts)
            }
        } catch (_: RuntimeException) { /* Account binding must still be cleared. */ }
    }
}

/** Separate, resizable documents let Android keep one bubble per conversation. */
class BubbleActivity : MainActivity()
