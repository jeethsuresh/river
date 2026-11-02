package cool.gravitas.river

import android.Manifest
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutManager
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.embedding.engine.FlutterEngineCache
import org.json.JSONObject
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith

/** Real Android notification and Flutter hosts; disposable emulator only. */
@RunWith(AndroidJUnit4::class)
class ConversationBubblesTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val c = instrumentation.targetContext
    private val manager get() = c.getSystemService(NotificationManager::class.java)
    private val subject = "11111111-1111-4111-8111-111111111111"
    private val room = "!bubble:gravitas.cool"
    private val sessionKey = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_river_session"
    private fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(
        instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
    private fun await(condition: () -> Boolean) {
        val deadline = System.nanoTime() + 40_000_000_000L
        while (!condition() && System.nanoTime() < deadline) Thread.sleep(50)
        assertTrue("Android bubble state did not settle", condition())
    }
    private fun notifications() = manager.activeNotifications.filter { it.tag?.startsWith("river:") == true }
    private fun deliver(sequence: Long, target: String = room) = StorePush.deliver(c, JSONObject()
        .put("kind", "matrix.event").put("issuer", "https://gravitas.cool").put("subject", subject)
        .put("room_id", target).put("event_id", "$" + sequence).put("sequence", sequence).toString())

    @Before fun setup() {
        org.junit.Assume.assumeTrue(Build.VERSION.SDK_INT >= 30)
        StorePush.clear(c)
        c.getSharedPreferences("river.push", Context.MODE_PRIVATE).edit().clear().commit()
        c.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE).edit().putString(sessionKey, "bubble-test-session").commit()
        StorePush.bind(c, "https://gravitas.cool", subject)
        if (Build.VERSION.SDK_INT >= 33) instrumentation.uiAutomation.grantRuntimePermission(c.packageName, Manifest.permission.POST_NOTIFICATIONS)
        StorePush.enable(c, true)
        shell("settings put secure notification_bubbles 1")
        shell("cmd notification set_bubbles ${c.packageName} 0")
        await { notifications().isEmpty() }
    }

    @After fun cleanup() {
        StorePush.clear(c)
        shell("cmd notification set_bubbles ${c.packageName} 0")
        c.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE).edit().remove(sessionKey).commit()
        await { notifications().isEmpty() }
    }

    @Test fun publishesPrivateConversationMetadataAndDistinctShortcuts() {
        deliver(10)
        await { notifications().size == 1 }
        val notification = notifications().single().notification
        val id = ConversationBubbles.id(subject, room)
        assertEquals(id, notification.shortcutId)
        assertNotNull(notification.bubbleMetadata)
        if (Build.VERSION.SDK_INT >= 31) assertFalse(notification.bubbleMetadata!!.intent!!.isImmutable)
        assertEquals(Notification.MessagingStyle::class.java.name, notification.extras.getString("android.template"))
        val shortcut = c.getSystemService(ShortcutManager::class.java).dynamicShortcuts.single { it.id == id }
        assertTrue(shortcut.isDynamic)
        assertEquals("River conversation", shortcut.shortLabel)
        assertEquals(BubbleActivity::class.java.name, shortcut.intent!!.component!!.className)
        assertEquals(room, shortcut.intent!!.getStringExtra("room_id"))
        assertEquals(subject, shortcut.intent!!.getStringExtra("subject"))
        assertNotEquals(id, ConversationBubbles.id("another-account", room))
        deliver(11, "!second:gravitas.cool")
        await { notifications().size == 2 }
        assertEquals(2, notifications().map { it.notification.shortcutId }.toSet().size)
    }

    @Test fun readingKeepsAnAllowedBubbleButDismissesAnOrdinaryAlert() {
        deliver(10)
        await { notifications().size == 1 }
        StorePush.read(c, room)
        await { notifications().isEmpty() }
        shell("cmd notification set_bubbles ${c.packageName} 1")
        deliver(11)
        await { (notifications().singleOrNull()?.notification?.flags ?: 0) and Notification.FLAG_BUBBLE != 0 }
        assertTrue(notifications().single().notification.flags and Notification.FLAG_BUBBLE != 0)
        StorePush.read(c, room)
        assertEquals(1, notifications().size)
        StorePush.clear(c)
        await { notifications().isEmpty() }
        assertTrue(c.getSystemService(ShortcutManager::class.java).dynamicShortcuts.none { it.id == ConversationBubbles.id(subject, room) })
    }

    @Test fun switchingHostsReusesOneRunningFlutterEngine() {
        // Native-delivery tests use an opaque stand-in, not real encrypted
        // credentials. Start Flutter signed out for this host lifecycle test.
        c.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE).edit().remove(sessionKey).commit()
        val first = instrumentation.startActivitySync(Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val engine = FlutterEngineCache.getInstance().get("river")!!
        fun rendered(): Boolean {
            var visible = false
            instrumentation.runOnMainSync { visible = engine.renderer.isDisplayingFlutterUi }
            return visible
        }
        try {
            await { rendered() }
            val bubble = instrumentation.startActivitySync(ConversationBubbles.intent(c, subject, room).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            try {
                await { rendered() }
                assertFalse(first.isDestroyed)
                assertSame(engine, FlutterEngineCache.getInstance().get("river"))
                val second = instrumentation.startActivitySync(ConversationBubbles.intent(c, subject, "!second:gravitas.cool").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                try {
                    await { rendered() }
                    assertFalse(bubble.isDestroyed)
                    assertSame(engine, FlutterEngineCache.getInstance().get("river"))
                    assertTrue(engine.dartExecutor.isExecutingDart)
                    // Re-enter the original documents, forcing their evicted
                    // views to attach again without losing either Android task.
                    val tasks = c.getSystemService(ActivityManager::class.java).appTasks
                    tasks.single { it.taskInfo.taskId == first.taskId }.moveToFront()
                    await { first.isDestroyed && rendered() }
                    tasks.single { it.taskInfo.taskId == bubble.taskId }.moveToFront()
                    await { bubble.isDestroyed && rendered() }
                    assertSame(engine, FlutterEngineCache.getInstance().get("river"))
                } finally { instrumentation.runOnMainSync { second.finish() } }
            } finally { instrumentation.runOnMainSync { bubble.finish() } }
        } finally { instrumentation.runOnMainSync { first.finish() } }
    }
}
