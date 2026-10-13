// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.FrameLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine

/**
 * The Ramble Voice keyboard. The UI is Flutter: a dedicated engine (spawned
 * from the shared group) runs `imeMain` from lib/main_ime.dart and renders into
 * a [FlutterView] that is the IME's input view.
 *
 * Rendering: [FlutterTextureView], not the default SurfaceView. A SurfaceView
 * punches a separate compositor layer, which misbehaves inside the input
 * method window (z-order against the app window, flicker while the window
 * animates in and out, wrong clipping with insets). A TextureView is an
 * ordinary view in the IME's hardware-accelerated window and animates with it,
 * at a small per-frame cost that is irrelevant for a mostly static keyboard.
 *
 * The engine has no Activity, so lifecycle is driven by hand: resumed while
 * the window is shown, paused when hidden, destroyed with the service.
 */
class RambleImeService : InputMethodService() {
    private var engine: FlutterEngine? = null
    private var flutterView: FlutterView? = null
    private var audio: AudioCaptureHandler? = null
    private var system: SystemHandler? = null
    private var ime: ImeHandler? = null
    private var container: FrameLayout? = null

    private var navInset = 0
    private var ignoreTouchesUntil = 0L

    override fun onCreate() {
        super.onCreate()
        io.github.luohoa97.ramblevoice.bubble.BubbleKeeper.sync(this)
        val e = (application as RambleApplication).createImeEngine(this)
        val messenger = e.dartExecutor.binaryMessenger
        audio = AudioCaptureHandler(applicationContext, messenger)
        system = SystemHandler(this, messenger) { window?.window?.decorView }
        ime = ImeHandler(this, messenger)
        e.lifecycleChannel.appIsInactive()
        engine = e
    }

    /** No extract (fullscreen) editor in landscape; the keyboard stays a panel. */
    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onCreateInputView(): View {
        val e = engine ?: (application as RambleApplication).createImeEngine(this).also { engine = it }
        val view = FlutterView(this, FlutterTextureView(this))
        view.attachToFlutterEngine(e)
        flutterView = view

        val frame = KeyboardFrame(this, ::keyboardHeightPx) { SystemClock.uptimeMillis() < ignoreTouchesUntil }
        frame.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        // Android 15+ draws the IME behind the navigation bar. Grow the panel by
        // the bar height; Flutter sees the same inset as viewPadding.
        ViewCompat.setOnApplyWindowInsetsListener(frame) { v, insets ->
            val bottom = insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom
            if (bottom != navInset) {
                navInset = bottom
                v.layoutParams = v.layoutParams?.apply { height = keyboardHeightPx() }
                v.requestLayout()
            }
            insets
        }
        container = frame
        return frame
    }

    private fun keyboardHeightPx(): Int {
        val metrics = resources.displayMetrics
        // Grow with the user's font size so larger text never crowds the keys.
        val fontScale = resources.configuration.fontScale.coerceIn(1f, 1.4f)
        val wanted = (KEYBOARD_HEIGHT_DP * fontScale * metrics.density).toInt()
        // Leave room for the app in landscape.
        val cap = (metrics.heightPixels * 0.6f).toInt()
        return minOf(wanted, cap) + navInset
    }

    /**
     * With a hardware keyboard attached the input view is usually not shown, so
     * `onStartInputView` never runs. A pending auto-start from the dictation key
     * is delivered here instead; the connection is all dictation needs.
     */
    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        if (ImeLaunch.hasPendingAutoStart()) {
            // Switched in by the floating mic: Android selects us but does not
            // show the window until the field asks again, so ask ourselves.
            CrashLog.note("ime requestShowSelf for bubble auto-start")
            requestShowSelf(0)
            ime?.notifyInputStarted(attribute, restarting)
        }
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        if (!restarting && ime?.needsTypingKeyboard(info) == true) {
            // PINs, codes, phone numbers and passwords are typed, not dictated:
            // hand the field to the user's typing keyboard straight away.
            CrashLog.note("ime hands a number/password field to the typing keyboard")
            ime?.switchToTypingKeyboard()
            return
        }
        engine?.lifecycleChannel?.appIsResumed()
        ImeLaunch.setImeShowing(true)
        ime?.notifyInputStarted(info, restarting)
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        ImeLaunch.setImeShowing(false)
        val rotating = SystemClock.uptimeMillis() - lastConfigChange < ROTATION_WINDOW_MS
        ime?.notifyInputFinished(finishingInput, rotating)
    }

    private var lastConfigChange = 0L

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        lastConfigChange = SystemClock.uptimeMillis()
        super.onConfigurationChanged(newConfig)
    }

    override fun onWindowShown() {
        super.onWindowShown()
        // The tap that switched keyboards must not land on one of our keys.
        ignoreTouchesUntil = SystemClock.uptimeMillis() + TOUCH_GUARD_MS
        engine?.lifecycleChannel?.appIsResumed()
    }

    override fun onWindowHidden() {
        super.onWindowHidden()
        engine?.lifecycleChannel?.appIsInactive()
        engine?.lifecycleChannel?.appIsPaused()
    }

    override fun onDestroy() {
        ImeLaunch.setImeShowing(false)
        val e = engine
        val view = flutterView
        val handler = ime
        engine = null
        flutterView = null
        ime = null
        container = null
        view?.detachFromFlutterEngine()

        audio?.dispose()
        system?.dispose()
        audio = null
        system = null

        if (e == null) {
            handler?.dispose()
        } else {
            // Let Dart free the Gemma model before the engine goes away.
            var destroyed = false
            val destroy = {
                if (!destroyed) {
                    destroyed = true
                    handler?.dispose()
                    e.lifecycleChannel.appIsDetached()
                    e.destroy()
                }
            }
            if (handler != null) {
                handler.requestRelease(destroy)
                Handler(Looper.getMainLooper()).postDelayed(destroy, RELEASE_TIMEOUT_MS)
            } else {
                destroy()
            }
        }
        super.onDestroy()
    }

    companion object {
        /** A keyboard hidden this soon after a configuration change was hidden by rotation. */
        private const val ROTATION_WINDOW_MS = 1500L
        private const val KEYBOARD_HEIGHT_DP = 248
        private const val RELEASE_TIMEOUT_MS = 2000L
        private const val TOUCH_GUARD_MS = 350L
    }
}

/**
 * The input view's container. The IME frame measures its child with
 * WRAP_CONTENT and a FlutterView would happily take the whole window, so the
 * height is forced to exactly [heightPx]. While [guarding] is true all touches
 * are swallowed.
 */
private class KeyboardFrame(
    context: android.content.Context,
    private val heightPx: () -> Int,
    private val guarding: () -> Boolean,
) : FrameLayout(context) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        super.onMeasure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(heightPx(), MeasureSpec.EXACTLY))
    }

    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean = guarding()

    @Suppress("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean = guarding()
}
