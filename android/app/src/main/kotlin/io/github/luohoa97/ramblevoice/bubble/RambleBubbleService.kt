// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice.bubble

import android.accessibilityservice.AccessibilityService
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.widget.Toast
import android.content.ComponentName
import android.view.inputmethod.InputMethodManager
import io.github.luohoa97.ramblevoice.ImeLaunch
import io.github.luohoa97.ramblevoice.R
import io.github.luohoa97.ramblevoice.RambleImeService

/**
 * The floating mic. While an editable, non-password field is focused in an
 * app that is not blocked, a small native bubble sits at the field's right
 * edge. Dictation itself runs in a headless Flutter engine
 * ([BubbleEngineHost]); this service owns the overlay, tracks the focused
 * field and inserts the result.
 *
 * Privacy: events are used only to learn which field is focused and where it
 * is. No screen content is read except the focused field's text, at the
 * moment of insertion, to splice the dictation into it. Nothing is stored.
 */
class RambleBubbleService : AccessibilityService(), BubbleView.Listener, BubbleEngineHost.Listener {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var prefs: BubblePrefs
    private lateinit var windowManager: WindowManager
    private lateinit var inserter: BubbleInserter
    private lateinit var host: BubbleEngineHost

    private var view: BubbleView? = null
    private var params: WindowManager.LayoutParams? = null

    /** The field the bubble is attached to. Re-resolved before inserting. */
    private var focusNode: AccessibilityNodeInfo? = null
    private var fieldBounds = Rect()
    private var fieldPackage: String? = null

    private var phase = BubblePhase.IDLE
    private var dragging = false
    private var holdStartedListening = false
    private var holdViaKeyboard = false

    private val evaluateRunnable = Runnable { evaluate() }
    private val hideRunnable = Runnable { if (!sessionActive()) removeBubble() }
    private val settleRunnable = Runnable { settle() }
    private val releaseRunnable = Runnable { host.sendIfRunning("release") }

    override fun onServiceConnected() {
        super.onServiceConnected()
        prefs = BubblePrefs(this)
        windowManager = getSystemService(WindowManager::class.java)
        inserter = BubbleInserter(this)
        prefs.wanted = true
        BubbleKeeper.schedulePeriodic(this)
        BubbleKeeper.check(this)
        host = BubbleEngineHost(this, { view }, this)
        ImeLaunch.onImeShowingChanged = {
            main.removeCallbacks(evaluateRunnable)
            main.post(evaluateRunnable)
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (!::prefs.isInitialized) return
        // Coalesce the burst of events one focus change produces.
        main.removeCallbacks(evaluateRunnable)
        main.postDelayed(evaluateRunnable, EVALUATE_DELAY_MS)
    }

    override fun onInterrupt() = Unit

    // Focus tracking ------------------------------------------------------

    private fun evaluate() {
        if (dragging) return
        // Our own keyboard is up: it has its own mic, so the bubble steps aside.
        if (ImeLaunch.imeShowing) {
            removeBubble()
            return
        }
        val candidate = focusedEditable()
        if (candidate == null) {
            if (!sessionActive()) main.postDelayed(hideRunnable, HIDE_DELAY_MS)
            return
        }
        main.removeCallbacks(hideRunnable)
        focusNode = candidate
        fieldPackage = candidate.packageName?.toString()
        candidate.getBoundsInScreen(fieldBounds)
        showOrMove()
    }

    /** The focused text field of the active app window, or null if the bubble must not show. */
    private fun focusedEditable(): AccessibilityNodeInfo? {
        val appWindow = windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_APPLICATION && it.isActive }
        val root = appWindow?.root ?: rootInActiveWindow ?: return null
        val node = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return null
        val pkg = node.packageName?.toString() ?: return null
        return node.takeIf {
            it.isEditable && !it.isPassword && it.isVisibleToUser &&
                pkg != packageName && pkg !in prefs.blockedApps && pkg != defaultKeyboardPackage()
        }
    }

    private fun defaultKeyboardPackage(): String? =
        Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)?.substringBefore('/')

    private fun sessionActive() = phase == BubblePhase.LISTENING || phase == BubblePhase.PROCESSING

    // Overlay ---------------------------------------------------------------

    private fun showOrMove() {
        val v = view ?: createBubble()
        val p = params ?: return
        val (x, y) = position(v.sizePx)
        p.x = x
        p.y = y
        if (v.isAttachedToWindow) windowManager.updateViewLayout(v, p) else windowManager.addView(v, p)
    }

    private fun createBubble(): BubbleView {
        val v = BubbleView(this, prefs.sizeDp)
        v.listener = this
        v.alpha = 0f
        view = v
        params = WindowManager.LayoutParams(
            v.sizePx,
            v.sizePx,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            title = "RambleBubble"
        }
        v.post { v.animate().alpha(1f).setDuration(120).start() }
        host.ensureStarted()
        return v
    }

    private fun removeBubble() {
        val v = view ?: return
        view = null
        params = null
        focusNode = null
        fieldPackage = null
        main.removeCallbacks(settleRunnable)
        v.animate().alpha(0f).setDuration(120).withEndAction {
            if (v.isAttachedToWindow) windowManager.removeView(v)
        }.start()
    }

    /** Screen-pixel limits for the bubble's top edge: below the status bar, above the keyboard. */
    private fun verticalLimits(size: Int): Pair<Int, Int> {
        val metrics = windowManager.currentWindowMetrics
        val insets = metrics.windowInsets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
        val margin = (MARGIN_DP * resources.displayMetrics.density).toInt()
        val imeTop = windows
            .filter { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            .minOfOrNull { w -> Rect().also { w.getBoundsInScreen(it) }.top }
        val bottom = minOf(imeTop ?: Int.MAX_VALUE, metrics.bounds.bottom - insets.bottom)
        val top = metrics.bounds.top + insets.top
        return top to maxOf(top, bottom - size - margin)
    }

    /** Where the bubble sits with no user offset: centred on the field, vertically. */
    private fun baseY(size: Int) = fieldBounds.centerY() - size / 2

    /** Top-left of the bubble in screen pixels: field's right edge, above the keyboard, on screen. */
    private fun position(size: Int): Pair<Int, Int> {
        val metrics = windowManager.currentWindowMetrics
        val insets = metrics.windowInsets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
        val density = resources.displayMetrics.density
        val screen = metrics.bounds
        val right = minOf(fieldBounds.right, screen.right - insets.right)
        val x = (right - size - (MARGIN_DP * density).toInt()).coerceIn(screen.left + insets.left, screen.right - insets.right - size)
        val (minY, maxY) = verticalLimits(size)
        return x to (baseY(size) + (prefs.offsetYDp * density).toInt()).coerceIn(minY, maxY)
    }

    // User gestures (BubbleView.Listener) ---------------------------------------

    override fun onTap() {
        // While a headless dictation is running the tap controls it; otherwise hand over to the keyboard.
        if (sessionActive() || !switchToRambleKeyboard(hold = false)) command("toggle")
    }

    override fun onHoldStart() {
        holdStartedListening = false
        holdViaKeyboard = false
        if (sessionActive()) return
        if (switchToRambleKeyboard(hold = true)) {
            holdViaKeyboard = true
        } else {
            holdStartedListening = true
            command("start")
        }
    }

    override fun onHoldEnd() {
        if (holdViaKeyboard) ImeLaunch.requestStop()
        if (holdStartedListening) command("stop")
        holdStartedListening = false
        holdViaKeyboard = false
    }

    /**
     * Switches the active keyboard to Ramble, which starts listening as soon as
     * it appears ([ImeLaunch]). Returns false (caller falls back to headless
     * dictation) when our keyboard is not enabled or the switch is refused.
     */
    private fun switchToRambleKeyboard(hold: Boolean): Boolean {
        val imm = getSystemService(InputMethodManager::class.java)
        val enabled = imm?.enabledInputMethodList?.any { it.packageName == packageName } == true
        if (!enabled) {
            Toast.makeText(this, R.string.bubble_enable_keyboard, Toast.LENGTH_LONG).show()
            return false
        }
        ImeLaunch.requestAutoStart(hold)
        val id = ComponentName(this, RambleImeService::class.java).flattenToShortString()
        // The return type differs across API levels (Boolean or a status Int); read it as Any.
        val result: Any = softKeyboardController.switchToInputMethod(id)
        val ok = when (result) {
            is Boolean -> result
            is Int -> result == 0
            else -> false
        }
        if (!ok) ImeLaunch.consumeAutoStart()
        return ok
    }

    override fun onCancel() = command("cancel")

    override fun onDrag(dy: Float) {
        val p = params ?: return
        val v = view ?: return
        dragging = true
        val (minY, maxY) = verticalLimits(v.sizePx)
        p.y = (p.y + dy.toInt()).coerceIn(minY, maxY)
        if (v.isAttachedToWindow) windowManager.updateViewLayout(v, p)
    }

    override fun onDragEnd() {
        val p = params ?: return
        val v = view ?: return
        prefs.offsetYDp = (p.y - baseY(v.sizePx)) / resources.displayMetrics.density
        dragging = false
    }

    private fun command(method: String) {
        if (phase == BubblePhase.IDLE || phase == BubblePhase.DONE || phase == BubblePhase.ERROR) {
            if (!host.isReady) applyPhase(BubblePhase.PROCESSING, 0f) // engine warming up
        }
        host.sendIfRunning("context", mapOf("packageName" to fieldPackage, "isMultiline" to (focusNode?.isMultiLine ?: false)))
        host.send(method)
    }

    // Dart -> Kotlin (BubbleEngineHost.Listener) ----------------------------------

    override fun onState(phase: BubblePhase, level: Float, message: String?) {
        applyPhase(phase, level)
        if (!message.isNullOrEmpty() && (phase == BubblePhase.ERROR || phase == BubblePhase.IDLE)) {
            Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        }
    }

    private fun applyPhase(next: BubblePhase, level: Float) {
        val previous = phase
        phase = next
        main.removeCallbacks(settleRunnable)
        main.removeCallbacks(releaseRunnable)
        view?.let { v ->
            v.setPhase(next, level)
            if (next != previous) when (next) {
                BubblePhase.DONE -> v.buzz(HapticFeedbackConstants.CONFIRM)
                BubblePhase.ERROR -> v.buzz(HapticFeedbackConstants.REJECT)
                else -> Unit
            }
        }
        when (next) {
            BubblePhase.DONE -> main.postDelayed(settleRunnable, DONE_HOLD_MS)
            BubblePhase.ERROR -> main.postDelayed(settleRunnable, ERROR_HOLD_MS)
            BubblePhase.IDLE -> scheduleReleaseAndHide()
            else -> Unit
        }
    }

    /** Back to the idle mic after a result or error has been shown. */
    private fun settle() {
        applyPhase(BubblePhase.IDLE, 0f)
    }

    private fun scheduleReleaseAndHide() {
        main.postDelayed(releaseRunnable, IDLE_RELEASE_MS)
        // Focus may have left while dictating.
        main.removeCallbacks(evaluateRunnable)
        main.postDelayed(evaluateRunnable, EVALUATE_DELAY_MS)
    }

    override fun onInsert(text: String, reply: (Boolean) -> Unit) {
        val node = resolveField()
        if (node == null) {
            inserter.setClip(text)
            Toast.makeText(this, R.string.bubble_copied_paste, Toast.LENGTH_SHORT).show()
            reply(false)
            return
        }
        inserter.insert(node, text, reply)
    }

    /** The field to insert into: the one focused right now, else the one the bubble was attached to. */
    private fun resolveField(): AccessibilityNodeInfo? {
        val live = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (live != null && live.isEditable && !live.isPassword) return live
        val last = focusNode ?: return null
        return if (last.refresh() && last.isEditable) last else null
    }

    // Memory ----------------------------------------------------------------

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= TRIM_MEMORY_BACKGROUND_LEVEL && !sessionActive()) host.sendIfRunning("release")
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        BubbleKeeper.scheduleSoon(this)
        shutdown()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        if (::prefs.isInitialized) BubbleKeeper.scheduleSoon(this)
        shutdown()
        super.onDestroy()
    }

    private fun shutdown() {
        if (!::prefs.isInitialized) return
        ImeLaunch.onImeShowingChanged = null
        main.removeCallbacksAndMessages(null)
        view?.let { if (it.isAttachedToWindow) windowManager.removeView(it) }
        view = null
        params = null
        focusNode = null
        host.dispose()
    }

    companion object {
        private const val EVALUATE_DELAY_MS = 60L
        private const val HIDE_DELAY_MS = 1000L
        private const val DONE_HOLD_MS = 900L
        private const val ERROR_HOLD_MS = 2500L
        private const val IDLE_RELEASE_MS = 3 * 60 * 1000L
        private const val MARGIN_DP = 8

        /** ComponentCallbacks2.TRIM_MEMORY_BACKGROUND, spelled out because the constant is deprecated. */
        private const val TRIM_MEMORY_BACKGROUND_LEVEL = 40
    }
}
