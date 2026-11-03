package cool.gravitas.river

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import io.flutter.embedding.engine.FlutterEngineCache

/** Disposable emulator only. Real OS notifications and background preview jobs. */
@RunWith(AndroidJUnit4::class)
class StoreNotificationDeliveryTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val c = instrumentation.targetContext
    private val manager get() = c.getSystemService(NotificationManager::class.java)
    private val key = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_river_session"
    private val subject = "11111111-1111-4111-8111-111111111111"
    private fun session(value: String?) {
        check(c.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE).edit().putString(key, value).commit())
    }
    private fun payload(sequence: Long = 10, owner: String = subject) = JSONObject()
        .put("kind", "matrix.event").put("issuer", "https://gravitas.cool").put("subject", owner)
        .put("room_id", "!room:gravitas.cool").put("event_id", "$" + sequence).put("sequence", sequence).toString()
    private fun notifications() = manager.activeNotifications.filter { it.tag?.startsWith("river:") == true }
    private fun await(seconds: Long = 10, condition: () -> Boolean) {
        val deadline = System.nanoTime() + seconds * 1_000_000_000L
        while (!condition() && System.nanoTime() < deadline) Thread.sleep(20)
        assertTrue("Android notification state did not settle", condition())
    }
    private val permissionDenied get() = InstrumentationRegistry.getArguments().getString("permissionDenied") == "true"
    @Before fun setup() {
        c.getSharedPreferences("river.push", Context.MODE_PRIVATE).edit().clear().commit()
        StorePush.clear(c)
        session("encrypted-disposable-session")
        StorePush.bind(c, "https://gravitas.cool", subject)
        if (Build.VERSION.SDK_INT >= 33 && !permissionDenied) {
            instrumentation.uiAutomation.grantRuntimePermission(c.packageName, Manifest.permission.POST_NOTIFICATIONS)
        }
        StorePush.enable(c, true)
        await { notifications().isEmpty() }
        if (!permissionDenied) await { StorePush.allowed(c) }
    }
    @After fun cleanup() {
        StorePush.clear(c)
        await { notifications().isEmpty() }
        c.getSharedPreferences("river.push", Context.MODE_PRIVATE).edit().clear().commit()
        session(null)
    }
    @Test fun displaysPrivateNativeAlertAndSuppressesReplay() {
        StorePush.deliver(c, payload())
        await { notifications().size == 1 }
        val first = notifications().single()
        // MessagingStyle derives its title from the generic conversation Person.
        assertEquals(if (Build.VERSION.SDK_INT >= 30) "Conversation" else "River",
            first.notification.extras.getCharSequence("android.title").toString())
        assertEquals("New conversation activity", first.notification.extras.getString("android.text"))
        assertEquals(c.packageName, first.notification.contentIntent.creatorPackage)
        if (Build.VERSION.SDK_INT >= 31) assertTrue(first.notification.contentIntent.isImmutable)
        Thread.sleep(20)
        StorePush.deliver(c, payload())
        StorePush.deliver(c, payload(9))
        assertEquals(first.postTime, notifications().single().postTime)
        StorePush.deliver(c, payload(11))
        await { notifications().singleOrNull()?.postTime?.let { it > first.postTime } == true }
        assertTrue(notifications().single().postTime > first.postTime)
        StorePush.read(c, "!room:gravitas.cool")
        await { notifications().isEmpty() }
        assertTrue(notifications().isEmpty())
        StorePush.deliver(c, payload(11))
        assertTrue(notifications().isEmpty())
    }
    @Test fun rejectsWrongAccountSignOutAndSessionReplacement() {
        StorePush.deliver(c, payload(owner = "another-account"))
        assertTrue(notifications().isEmpty())
        session("rotated-session")
        StorePush.deliver(c, payload())
        assertTrue(notifications().isEmpty())
        StorePush.bind(c, "https://gravitas.cool", subject)
        StorePush.deliver(c, payload())
        await { notifications().size == 1 }
        assertEquals(1, notifications().size)
        StorePush.clear(c)
        await { notifications().isEmpty() }
        StorePush.deliver(c, payload(11))
        assertTrue(notifications().isEmpty())
        session(null)
        StorePush.bind(c, "https://gravitas.cool", subject)
        StorePush.deliver(c, payload(12))
        assertTrue(notifications().isEmpty())
    }
    @Test fun respectsSystemPermissionAndExplicitDisable() {
        StorePush.enable(c, false)
        StorePush.deliver(c, payload())
        assertTrue(notifications().isEmpty())
        StorePush.enable(c, true)
        if (permissionDenied) {
            assertFalse(StorePush.allowed(c))
            StorePush.deliver(c, payload())
            assertTrue(notifications().isEmpty())
        } else {
            assertTrue(StorePush.allowed(c))
        }
    }
    @Test fun rejectsUnsignedBinderCaller() {
        try {
            c.contentResolver.call(Uri.parse("content://cool.gravitas.river.notifications"), "notify", null, Bundle().apply { putString("payload", payload()) })
            fail("River's own UID must not impersonate signed Private Store")
        } catch (_: SecurityException) { }
        assertTrue(notifications().isEmpty())
    }

    @Test fun richPreviewsStayPrivateAndCannotReviveReadOrNewerAlerts() {
        val preview = mapOf("title" to "Friends", "sender" to "Bob", "body" to "Hello 🌊🔐")
        lateinit var first: JSONObject
        instrumentation.runOnMainSync {
            StorePush.deliver(c, payload())
            first = StorePush.pending(c).single()
            StorePush.enrich(c, first, preview)
            StorePush.finishPreview(c, first)
        }
        await { notifications().singleOrNull()?.notification?.extras?.getString("android.text")?.contains("Hello 🌊🔐") == true }
        val rich = notifications().single().notification
        assertEquals(android.app.Notification.VISIBILITY_PRIVATE, rich.visibility)
        assertEquals("River", rich.publicVersion.extras.getCharSequence("android.title").toString())
        assertEquals("New conversation activity", rich.publicVersion.extras.getString("android.text"))
        assertTrue(rich.flags and android.app.Notification.FLAG_ONLY_ALERT_ONCE != 0)
        instrumentation.runOnMainSync {
            StorePush.deliver(c, payload(11))
            StorePush.enrich(c, first, preview)
        }
        await { notifications().singleOrNull()?.notification?.extras?.getString("android.text") == "New conversation activity" }
        instrumentation.runOnMainSync {
            StorePush.deliver(c, payload(12))
            val latest = StorePush.pending(c).single()
            StorePush.read(c, "!room:gravitas.cool")
            StorePush.enrich(c, latest, preview)
        }
        await { notifications().isEmpty() }
        instrumentation.runOnMainSync {
            StorePush.deliver(c, payload(13))
            val signedOut = StorePush.pending(c).single()
            StorePush.clear(c)
            StorePush.enrich(c, signedOut, preview)
        }
        await { notifications().isEmpty() }
        assertTrue(StorePush.pending(c).isEmpty())
    }

    @Test fun backgroundJobStartsHeadlessAndOpeningRiverPromotesTheSameEngine() {
        StorePush.deliver(c, payload())
        var running = false
        await(40) {
            instrumentation.runOnMainSync {
                running = FlutterEngineCache.getInstance().get("river")?.dartExecutor?.isExecutingDart == true
            }
            running
        }
        val engine = FlutterEngineCache.getInstance().get("river")!!
        var rendered = false
        instrumentation.runOnMainSync { rendered = engine.renderer.isDisplayingFlutterUi }
        assertFalse("Background decryption must not start the app UI", rendered)
        await(40) { StorePush.pending(c).isEmpty() }
        assertEquals("New conversation activity", notifications().single().notification.extras.getString("android.text"))
        // The stand-in ciphertext above is only for native binding. Foreground
        // startup uses an empty real credential store in this disposable test.
        session(null)
        val activity = instrumentation.startActivitySync(Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        try {
            await(40) {
                instrumentation.runOnMainSync { rendered = engine.renderer.isDisplayingFlutterUi }
                rendered
            }
            assertSame(engine, FlutterEngineCache.getInstance().get("river"))
            val booted = java.util.concurrent.atomic.AtomicBoolean(false)
            instrumentation.runOnMainSync {
                NotificationRuntime.preview(c, JSONObject().put("subject", subject).put("room_id", "!room:gravitas.cool").put("event_id", "$" + "10")) {
                    booted.set(true)
                }
            }
            await(40) { booted.get() }
        } finally { instrumentation.runOnMainSync { activity.finish() } }
    }
}
