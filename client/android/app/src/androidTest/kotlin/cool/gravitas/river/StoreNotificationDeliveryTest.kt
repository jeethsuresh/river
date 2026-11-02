package cool.gravitas.river

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith

/** Disposable emulator only. Real OS notifications; no Activity or Flutter. */
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
    private fun await(condition: () -> Boolean) {
        val deadline = System.nanoTime() + 10_000_000_000L
        while (!condition() && System.nanoTime() < deadline) Thread.sleep(20)
        assertTrue("Android notification state did not settle", condition())
    }
    private fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
    @Before fun setup() {
        c.getSharedPreferences("river.push", Context.MODE_PRIVATE).edit().clear().commit()
        StorePush.clear(c)
        session("encrypted-disposable-session")
        StorePush.bind(c, "https://gravitas.cool", subject)
        if (Build.VERSION.SDK_INT >= 33) instrumentation.uiAutomation.grantRuntimePermission(c.packageName, Manifest.permission.POST_NOTIFICATIONS)
        StorePush.enable(c, true)
        await { notifications().isEmpty() }
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
        assertEquals("River", first.notification.extras.getString("android.title"))
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
        shell("appops set ${c.packageName} POST_NOTIFICATION ignore")
        try {
            await { !StorePush.allowed(c) }
            assertFalse(StorePush.allowed(c))
            StorePush.deliver(c, payload())
            assertTrue(notifications().isEmpty())
        } finally { shell("appops set ${c.packageName} POST_NOTIFICATION allow") }
    }
    @Test fun rejectsUnsignedBinderCaller() {
        try {
            c.contentResolver.call(Uri.parse("content://cool.gravitas.river.notifications"), "notify", null, Bundle().apply { putString("payload", payload()) })
            fail("River's own UID must not impersonate signed Private Store")
        } catch (_: SecurityException) { }
        assertTrue(notifications().isEmpty())
    }
}
