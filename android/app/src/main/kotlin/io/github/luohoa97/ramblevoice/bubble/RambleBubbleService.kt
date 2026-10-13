// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice.bubble

import io.github.luohoa97.ramblevoice.CorrectionWatch
import io.github.luohoa97.ramblevoice.CrashLog
import android.accessibilityservice.AccessibilityService
import android.animation.ValueAnimator
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
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
    private var fieldPackage: String? = null

    private var phase = BubblePhase.IDLE
    private var dragging = false
    private var revealed = false
    private var holdStartedListening = false
    private var holdViaKeyboard = false
    private var hotkeyHeld = false

    private val evaluateRunnable = Runnable { evaluate() }
    private val hideRunnable = Runnable { if (!sessionActive()) removeBubble() }
    private val settleRunnable = Runnable { settle() }
    private val tuckRunnable = Runnable { tuck() }
    private val releaseRunnable = Runnable { host.sendIfRunning("release") }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
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
        trackCorrections(event)
        // Coalesce the burst of events one focus change produces.
        main.removeCallbacks(evaluateRunnable)
        main.postDelayed(evaluateRunnable, EVALUATE_DELAY_MS)
    }

    override fun onInterrupt() = Unit

    // Physical keyboard dictation key ----------------------------------------------

    /**
     * Only the configured dictation key is acted on (and only while a real
     * keyboard sends it and a text field is focused); every other key, and every
     * event while the setting is off, passes through untouched and unread.
     */
    override fun onKeyEvent(event: KeyEvent): Boolean {
        if (!::prefs.isInitialized) return false
        if (BubbleHotkey.isRecording() && !BubbleHotkey.isSystemKey(event.keyCode)) {
            if (event.action == KeyEvent.ACTION_DOWN) BubbleHotkey.deliver(event.keyCode)
            return true
        }
        if (!prefs.hotkeyEnabled || event.keyCode != prefs.hotkeyCode) return false
        if (!BubbleHotkey.isHardwareKeyboard(event.deviceId)) return false
        return when (event.action) {
            KeyEvent.ACTION_DOWN -> when {
                event.repeatCount > 0 -> hotkeyHeld
                focusedEditable(requireKeyboard = false) == null -> false
                else -> {
                    hotkeyHeld = true
                    onHoldStart()
                    true
                }
            }
            KeyEvent.ACTION_UP -> if (hotkeyHeld) {
                hotkeyHeld = false
                onHoldEnd()
                true
            } else {
                false
            }
            else -> false
        }
    }

    // Focus tracking ------------------------------------------------------

    private fun evaluate() {
        if (dragging) return
        // Our own keyboard is up: it has its own mic, so the bubble steps aside.
        // The flag can go stale if the keyboard is torn down without a hide
        // callback, so only trust it while Ramble is the current keyboard.
        val ownKeyboard = defaultKeyboardPackage() == packageName
        if (ownKeyboard && (ImeLaunch.imeShowing || keyboardVisible()) && !sessionActive()) {
            // Also when the flag missed a show (a note app's format panel
            // re-showing the keyboard without a new input view).
            noteDecision(null, "hide: Ramble keyboard is up")
            removeBubble()
            return
        }
        if (ImeLaunch.imeShowing) ImeLaunch.setImeShowing(false)
        val candidate = focusedEditable()
        noteDecision(candidate)
        // The handle belongs to a visible keyboard (any IME); a running dictation keeps it up regardless.
        if (candidate == null || (!keyboardVisible() && !sessionActive())) {
            if (!sessionActive()) main.postDelayed(hideRunnable, HIDE_DELAY_MS)
            return
        }
        main.removeCallbacks(hideRunnable)
        focusNode = candidate
        fieldPackage = candidate.packageName?.toString()
        showOrMove()
    }

    private fun keyboardVisible() = imeHeight(windows) >= MIN_IME_HEIGHT_DP * density

    /**
     * Height of the on-screen keyboard, 0 when none. Some systems keep an
     * empty or tiny input-method window listed after the keyboard closes
     * (or for a gesture-bar switcher), so only real height counts.
     */
    private fun imeHeight(all: List<AccessibilityWindowInfo>): Int = all
        .filter { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
        .maxOfOrNull { w -> Rect().also { w.getBoundsInScreen(it) }.height() } ?: 0

    /** The focused text field of the active app window, or null if the bubble must not show. */
    /**
     * What the bubble attaches to: the focused editable node when the app
     * exposes one, otherwise (many React Native, Compose and web apps don't)
     * the app window's root whenever a keyboard is on screen, like Wispr Flow.
     * Null when the bubble must not show: no keyboard and no editable focus,
     * a password field, our own app, a blocked app, or the keyboard's own UI.
     */
    private fun focusedEditable(requireKeyboard: Boolean = true): AccessibilityNodeInfo? {
        val all = windows
        val imeVisible = imeHeight(all) >= MIN_IME_HEIGHT_DP * density
        val appRoots = all.filter { it.type == AccessibilityWindowInfo.TYPE_APPLICATION }
            .sortedByDescending { it.isActive || it.isFocused }
            .mapNotNull { it.root }
            .ifEmpty { listOfNotNull(rootInActiveWindow) }
        val focus = appRoots.firstNotNullOfOrNull { it.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) }
        if (focus?.isPassword == true) return null
        // Numbers, PINs and codes are typed (the Ramble keyboard hands them back too).
        val cls = (focus?.inputType ?: 0) and android.text.InputType.TYPE_MASK_CLASS
        if (cls == android.text.InputType.TYPE_CLASS_NUMBER || cls == android.text.InputType.TYPE_CLASS_PHONE ||
            cls == android.text.InputType.TYPE_CLASS_DATETIME
        ) {
            return null
        }
        // A keyboard is a precondition: a field that keeps focus after the
        // keyboard is dismissed (chat apps do) must not keep the bubble.
        // A hardware keyboard hotkey needs only an editable field.
        if (!imeVisible && (requireKeyboard || focus?.isEditable != true)) return null
        val target = when {
            focus != null && focus.isEditable -> focus
            // Apps that hide their editor from accessibility (some React
            // Native, Compose and web views) report no focus at all.
            focus == null -> appRoots.firstOrNull()
            else -> null
        } ?: return null
        val pkg = target.packageName?.toString() ?: return null
        return target.takeIf {
            (pkg != packageName || ImeLaunch.allowInOwnApp) && pkg !in prefs.blockedApps && pkg != defaultKeyboardPackage()
        }
    }

    private var lastNote = ""

    /** One line per change in the bubble's decision, to the local crash log. */
    private fun noteDecision(candidate: AccessibilityNodeInfo?, reason: String? = null) {
        val ime = (imeHeight(windows) / density).toInt()
        val note = if (reason != null) {
            reason
        } else if (candidate != null) {
            "show for ${candidate.packageName} (keyboard ${ime}dp)"
        } else if (ime < MIN_IME_HEIGHT_DP) {
            "hide: no keyboard (${ime}dp)"
        } else {
            val root = rootInActiveWindow
            val focus = root?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            when {
                root == null -> "hide: no active window"
                focus == null -> "hide: no input focus in ${root.packageName}"
                !focus.isEditable -> "hide: focus not editable in ${focus.packageName}"
                focus.isPassword -> "hide: password field"
                else -> "hide: excluded ${focus.packageName}"
            }
        }
        if (note != lastNote) {
            lastNote = note
            CrashLog.note("bubble $note")
        }
    }

    private fun defaultKeyboardPackage(): String? =
        Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)?.substringBefore('/')

    private fun sessionActive() = phase == BubblePhase.LISTENING || phase == BubblePhase.PROCESSING

    // Overlay: docked handle ------------------------------------------------------

    private val density get() = resources.displayMetrics.density
    private val landscape get() = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE

    private fun screen() = windowManager.currentWindowMetrics.bounds

    private fun insets() = windowManager.currentWindowMetrics.windowInsets
        .getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())

    /** Top edge limits for the handle: below the status bar, above the keyboard. */
    private fun verticalLimits(height: Int): Pair<Int, Int> {
        val insets = insets()
        val margin = (MARGIN_DP * density).toInt()
        val imeTop = windows
            .filter { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            .minOfOrNull { w -> Rect().also { w.getBoundsInScreen(it) }.top }
        val bottom = minOf(imeTop ?: Int.MAX_VALUE, screen().bottom - insets.bottom)
        val top = screen().top + insets.top
        return top to maxOf(top, bottom - height - margin)
    }

    /** Resting position: on the docked edge, tucked 40% off-screen unless revealed or expanded. */
    private fun dockedPosition(v: BubbleView): Pair<Int, Int> {
        val s = screen()
        val insets = insets()
        val w = v.widthPx
        val margin = (MARGIN_DP * density).toInt()
        val out = revealed || v.expanded
        val x = when {
            prefs.dockRight && out -> s.right - insets.right - w - margin
            prefs.dockRight -> s.right - (w * (1 - TUCK)).toInt()
            out -> s.left + insets.left + margin
            else -> s.left - (w * TUCK).toInt()
        }
        val (minY, maxY) = verticalLimits(v.circleSizePx)
        val y = (prefs.yFraction(landscape) * s.height() - v.circleSizePx / 2).toInt().coerceIn(minY, maxY)
        return x to y
    }

    private fun showOrMove() {
        if (dragging) return
        val v = view ?: createBubble()
        val p = params ?: return
        p.width = v.widthPx
        val (x, y) = dockedPosition(v)
        if (v.isAttachedToWindow && v.width != p.width) windowManager.updateViewLayout(v, p)
        if (!v.isAttachedToWindow) {
            p.x = x
            p.y = y
            windowManager.addView(v, p)
            v.post { v.animate().alpha(if (revealed || v.expanded) 1f else IDLE_ALPHA).setDuration(160).start() }
        } else {
            glideTo(v, p, x, y, spring = false)
        }
    }

    private fun createBubble(): BubbleView {
        val v = BubbleView(this, prefs.sizeDp)
        v.listener = this
        v.alpha = 0f
        view = v
        params = WindowManager.LayoutParams(
            v.widthPx,
            v.circleSizePx,
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
        host.ensureStarted()
        return v
    }

    private var glide: ValueAnimator? = null

    /** Moves the window to ([x], [y]); [spring] adds the overshoot used when snapping to an edge. */
    private fun glideTo(v: BubbleView, p: WindowManager.LayoutParams, x: Int, y: Int, spring: Boolean) {
        glide?.cancel()
        val fromX = p.x
        val fromY = p.y
        if (fromX == x && fromY == y) return
        glide = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = if (spring) 360L else 200L
            interpolator = if (spring) OvershootInterpolator(1.4f) else DecelerateInterpolator()
            addUpdateListener {
                if (!v.isAttachedToWindow) return@addUpdateListener
                val f = it.animatedValue as Float
                p.x = fromX + ((x - fromX) * f).toInt()
                p.y = fromY + ((y - fromY) * f).toInt()
                windowManager.updateViewLayout(v, p)
            }
            start()
        }
        v.animate().alpha(if (revealed || v.expanded) 1f else IDLE_ALPHA).setDuration(160).start()
    }

    private fun removeBubble() {
        val v = view ?: return
        view = null
        params = null
        focusNode = null
        fieldPackage = null
        revealed = false
        glide?.cancel()
        main.removeCallbacks(settleRunnable)
        main.removeCallbacks(tuckRunnable)
        v.animate().alpha(0f).setDuration(120).withEndAction {
            if (v.isAttachedToWindow) windowManager.removeView(v)
        }.start()
    }

    /** Slides out for interaction and back to the tucked, translucent rest state afterwards. */
    private fun reveal() {
        main.removeCallbacks(tuckRunnable)
        revealed = true
        showOrMove()
    }

    private fun scheduleTuck() {
        main.removeCallbacks(tuckRunnable)
        main.postDelayed(tuckRunnable, TUCK_DELAY_MS)
    }

    private fun tuck() {
        if (dragging || sessionActive() || phase != BubblePhase.IDLE) return
        revealed = false
        showOrMove()
    }

    // User gestures (BubbleView.Listener) ---------------------------------------

    override fun onPress() = reveal()

    override fun onReleased() {
        if (!dragging) scheduleTuck()
    }

    override fun onDragStart() {
        dragging = true
        glide?.cancel()
        main.removeCallbacks(tuckRunnable)
        view?.animate()?.alpha(1f)?.setDuration(100)?.start()
    }

    override fun onDrag(dx: Float, dy: Float) {
        val p = params ?: return
        val v = view ?: return
        val s = screen()
        p.x = (p.x + dx.toInt()).coerceIn(s.left, s.right - v.widthPx)
        p.y = (p.y + dy.toInt()).coerceIn(s.top, s.bottom - v.circleSizePx)
        if (v.isAttachedToWindow) windowManager.updateViewLayout(v, p)
    }

    override fun onDragEnd() {
        val p = params ?: return
        val v = view ?: return
        // Snap to the nearest edge and remember where it was dropped.
        val s = screen()
        prefs.dockRight = p.x + v.widthPx / 2 > s.centerX()
        val (minY, maxY) = verticalLimits(v.circleSizePx)
        val y = p.y.coerceIn(minY, maxY)
        prefs.setYFraction(landscape, (y + v.circleSizePx / 2f) / s.height())
        dragging = false
        revealed = true
        val (x, ty) = dockedPosition(v)
        glideTo(v, p, x, ty, spring = true)
        v.buzz(HapticFeedbackConstants.CLOCK_TICK)
        scheduleTuck()
    }

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
            if (next != previous || params?.width != v.widthPx) {
                // Busy phases keep the handle out; the pill needs a wider window.
                if (next == BubblePhase.IDLE) scheduleTuck() else {
                    main.removeCallbacks(tuckRunnable)
                    revealed = true
                }
                main.post { showOrMove() }
            }
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
        val pkg = node.packageName?.toString()
        inserter.insert(node, text) { ok ->
            reply(ok)
            if (ok) main.postDelayed({ CorrectionWatch.start(this, pkg, focusedFieldText(), text.trim()) }, 800)
        }
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
        if (instance === this) instance = null
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

    /** Feeds [CorrectionWatch]: the watched field's text as it is edited, and leaving it. */
    private fun trackCorrections(event: AccessibilityEvent) {
        val watched = CorrectionWatch.watchedPackage ?: return
        val pkg = event.packageName?.toString()
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED, AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED -> {
                val source = event.source ?: return
                if (!source.isPassword && source.isEditable) CorrectionWatch.onText(this, pkg, source.text?.toString())
            }
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, AccessibilityEvent.TYPE_VIEW_FOCUSED -> {
                // Another app (not a keyboard, not us) took over: the edit is over.
                if (pkg != null && pkg != watched && pkg != packageName && !isKeyboardPackage(pkg)) {
                    CorrectionWatch.finish(this)
                }
            }
        }
    }

    private fun isKeyboardPackage(pkg: String): Boolean {
        val imm = getSystemService(android.view.inputmethod.InputMethodManager::class.java) ?: return false
        return imm.enabledInputMethodList.any { it.packageName == pkg }
    }

    /** The focused field's whole text (null for passwords or when unreadable). */
    fun focusedFieldText(): String? {
        val focus = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return null
        if (focus.isPassword || !focus.isEditable) return null
        return focus.text?.toString()
    }

    /**
     * The text shown in the app being dictated into (a chat's recent messages,
     * an email being replied to), top to bottom, at most [maxChars] from the
     * end. Only called when the user turned on "Conversation context", at the
     * start of a dictation; nothing is kept. Skips our own app, keyboards,
     * password fields and the field being typed in.
     */
    fun screenText(maxChars: Int): String? {
        val root = windows
            .filter { it.type == AccessibilityWindowInfo.TYPE_APPLICATION }
            .sortedByDescending { it.isActive || it.isFocused }
            .firstNotNullOfOrNull { it.root }
            ?: return null
        if (root.packageName?.toString() == packageName) return null
        val lines = mutableListOf<Pair<Rect, String>>()
        fun walk(node: AccessibilityNodeInfo, depth: Int) {
            if (depth > 40 || lines.size > 400) return
            if (!node.isVisibleToUser || node.isPassword) return
            if (!node.isEditable) {
                val text = (node.text ?: node.contentDescription)?.toString()?.trim()
                if (!text.isNullOrEmpty() && text.length > 1) {
                    lines += Rect().also { node.getBoundsInScreen(it) } to text.replace(Regex("\\s+"), " ")
                }
            }
            for (i in 0 until node.childCount) node.getChild(i)?.let { walk(it, depth + 1) }
        }
        walk(root, 0)
        val ordered = lines.sortedWith(compareBy({ it.first.top }, { it.first.left })).map { it.second }.distinct()
        val joined = ordered.joinToString("\n")
        return joined.takeLast(maxChars).ifBlank { null }
    }

    companion object {
        /** The running service, for the keyboard's conversation context. */
        @Volatile var instance: RambleBubbleService? = null
            private set

        private const val EVALUATE_DELAY_MS = 60L
        private const val HIDE_DELAY_MS = 1000L
        /** Smaller input-method windows are not a keyboard. */
        private const val MIN_IME_HEIGHT_DP = 120
        private const val DONE_HOLD_MS = 900L
        private const val ERROR_HOLD_MS = 2500L
        private const val IDLE_RELEASE_MS = 3 * 60 * 1000L
        private const val MARGIN_DP = 8

        /** Share of the idle handle that sits off-screen. */
        private const val TUCK = 0.4f
        private const val IDLE_ALPHA = 0.7f
        private const val TUCK_DELAY_MS = 2000L

        /** ComponentCallbacks2.TRIM_MEMORY_BACKGROUND, spelled out because the constant is deprecated. */
        private const val TRIM_MEMORY_BACKGROUND_LEVEL = 40
    }
}
