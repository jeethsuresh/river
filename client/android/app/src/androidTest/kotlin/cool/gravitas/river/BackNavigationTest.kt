package cool.gravitas.river

import android.content.Intent
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Run only against tool/android_back_smoke.dart in a disposable emulator. */
@RunWith(AndroidJUnit4::class)
class BackNavigationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val c = instrumentation.targetContext
    private var activity: MainActivity? = null
    private var lastState: Any? = null
    private fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(
        instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
    private fun await(message: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + 30_000_000_000L
        while (!condition() && System.nanoTime() < deadline) Thread.sleep(50)
        assertTrue("$message; Dart state=$lastState; focused=${activity?.hasWindowFocus()}; registered=${activity?.backCallbackState}", condition())
    }
    private fun drawer(): Boolean? {
        val done = CountDownLatch(1)
        var opened: Boolean? = null
        instrumentation.runOnMainSync {
            val engine = FlutterEngineCache.getInstance().get("river")
            if (engine == null) { done.countDown(); return@runOnMainSync }
            MethodChannel(engine.dartExecutor.binaryMessenger, "cool.gravitas.river/back-smoke")
                .invokeMethod("state", null, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        lastState = result
                        opened = (result as? Map<*, *>)?.get("drawer") as? Boolean
                        done.countDown()
                    }
                    override fun error(code: String, message: String?, details: Any?) { done.countDown() }
                    override fun notImplemented() { done.countDown() }
                })
        }
        check(done.await(5, TimeUnit.SECONDS)) { "River did not answer the UI state query" }
        return opened
    }
    private fun launch(): MainActivity {
        val host = instrumentation.startActivitySync(
            Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        activity = host
        await("River's signed-in fixture did not become visible") {
            var rendered = false
            instrumentation.runOnMainSync {
                rendered = FlutterEngineCache.getInstance().get("river")?.renderer?.isDisplayingFlutterUi == true
            }
            host.hasWindowFocus() && rendered && drawer() == false
        }
        instrumentation.waitForIdleSync()
        instrumentation.uiAutomation.waitForIdle(500, 10_000)
        return host
    }
    private fun swipe(right: Boolean, cancel: Boolean = false) {
        val metrics = c.resources.displayMetrics
        val start = if (right) metrics.widthPixels - 2f else 1f
        val end = if (right) metrics.widthPixels * .55f else metrics.widthPixels * .45f
        val y = metrics.heightPixels * .45f
        val down = SystemClock.uptimeMillis()
        fun event(action: Int, x: Float) {
            val pointer = MotionEvent.PointerProperties().apply {
                id = 0
                toolType = MotionEvent.TOOL_TYPE_FINGER
            }
            val position = MotionEvent.PointerCoords().apply {
                this.x = x
                this.y = y
                pressure = if (action == MotionEvent.ACTION_UP) 0f else 1f
                size = 1f
            }
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 1,
                arrayOf(pointer), arrayOf(position), 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            // Hardware does not wait for the app to render between touch
            // samples. Synchronous injection can turn a swipe into a long press
            // on a busy software-rendered emulator and cancel Android Back.
            try { assertTrue(instrumentation.uiAutomation.injectInputEvent(event, false)) }
            finally { event.recycle() }
        }
        event(MotionEvent.ACTION_DOWN, start)
        for (step in 1..16) {
            SystemClock.sleep(16)
            event(MotionEvent.ACTION_MOVE, start + (end - start) * step / 16f)
        }
        if (cancel) for (step in 1..16) {
            SystemClock.sleep(16)
            event(MotionEvent.ACTION_MOVE, end + (start - end) * step / 16f)
        }
        event(MotionEvent.ACTION_UP, if (cancel) start else end)
    }

    @Before fun gestureNavigation() {
        if (shell("settings get secure navigation_mode").trim() != "2") {
            shell("cmd overlay enable-exclusive --category --user 0 com.android.internal.systemui.navbar.gestural")
        }
        shell("input keyevent KEYCODE_HOME")
        await("Gesture navigation must be enabled") { shell("settings get secure navigation_mode").trim() == "2" }
        // The settings value changes before SystemUI attaches its input monitor.
        await("Android's system edge-gesture handler must be ready") {
            shell("dumpsys activity service com.android.systemui/.SystemUIService")
                .split("EdgeBackGestureHandler:").drop(1).any { section ->
                    val state = section.lineSequence().take(12).joinToString("\n")
                    state.contains("mIsEnabled=true") && state.contains("mIsGestureHandlingEnabled=true")
                }
        }
    }
    @After fun cleanup() {
        activity?.let { host ->
            instrumentation.runOnMainSync { if (!host.isDestroyed) host.finish() }
            await("Android host did not finish cleanup") { host.isDestroyed }
        }
    }

    @Test fun eachGestureHasOneEffectAcrossRetainedActivityHosts() {
        var original: Any? = null
        // Both edges, repeatedly recreating the Android host without restarting Dart.
        for (attempt in 0..5) {
            val host = launch()
            val engine = FlutterEngineCache.getInstance().get("river")!!
            if (original == null) original = engine else assertSame(original, engine)
            swipe(right = attempt % 2 == 1)
            await("First OS swipe did not open the sidebar (attempt $attempt)") {
                host.hasWindowFocus() && !host.isFinishing && !host.isDestroyed && drawer() == true
            }
            Thread.sleep(350)
            assertFalse("One swipe must not also leave River", host.isFinishing || host.isDestroyed)
            assertTrue("One swipe must not also background River", host.hasWindowFocus())
            swipe(right = attempt % 2 == 0)
            await("Second OS swipe did not leave River (attempt $attempt)") { !host.hasWindowFocus() }
            assertEquals("Back must reach Dart before leaving River", false, drawer())
            // Android may retain a root task in the background. Explicitly
            // destroy that host to exercise a new Activity with the same engine.
            instrumentation.runOnMainSync { if (!host.isDestroyed) host.finish() }
            await("Old Android host was not destroyed") { host.isDestroyed }
            assertTrue(engine.dartExecutor.isExecutingDart)
        }
    }

    @Test fun cancelledGestureDoesNotOpenOrLeaveRiver() {
        val host = launch()
        for (right in listOf(false, true)) {
            swipe(right, cancel = true)
            Thread.sleep(500)
            assertFalse(host.isFinishing || host.isDestroyed)
            assertTrue(host.hasWindowFocus())
            assertEquals(false, drawer())
        }
        swipe(right = false)
        await("A committed gesture after cancellation must open the sidebar") { drawer() == true }
        swipe(right = true)
        await("Back from the open sidebar must leave River") { !host.hasWindowFocus() }
        assertEquals(false, drawer())
    }

    @Test fun systemBackButtonUsesTheSameTwoStepNavigation() {
        val host = launch()
        shell("input keyevent KEYCODE_BACK")
        await("First system Back button must open the sidebar") { host.hasWindowFocus() && drawer() == true }
        shell("input keyevent KEYCODE_BACK")
        await("Second system Back button must leave River") { !host.hasWindowFocus() }
        assertEquals(false, drawer())
    }
}
