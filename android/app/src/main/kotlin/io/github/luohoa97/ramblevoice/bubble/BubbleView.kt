// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice.bubble

import android.animation.ValueAnimator
import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.Drawable
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.animation.LinearInterpolator
import androidx.core.view.ViewCompat
import io.github.luohoa97.ramblevoice.R
import kotlin.math.abs

enum class BubblePhase { IDLE, LISTENING, PROCESSING, DONE, ERROR }

/**
 * The floating mic handle. Drawn by hand (circle, icon, spinner, and a pill
 * with a live waveform while listening) so it stays tiny and has no dependency
 * on Flutter or a theme.
 *
 * Gestures: tap, press and hold (hold-to-talk), and free dragging. The view
 * only reports intent; the service owns position, docking and dictation state.
 */
class BubbleView(context: Context, circleDp: Int) : View(context) {
    interface Listener {
        /** Finger touched down: the service slides the bubble fully out. */
        fun onPress()

        /** Finger lifted without tap, hold or drag. */
        fun onReleased()
        fun onTap()
        fun onHoldStart()
        fun onHoldEnd()
        fun onCancel()
        fun onDragStart()

        /** Finger moved the bubble by ([dx], [dy]) pixels since the last call. */
        fun onDrag(dx: Float, dy: Float)
        fun onDragEnd()
    }

    var listener: Listener? = null

    private val density = resources.displayMetrics.density
    private val circlePx = circleDp * density

    /** Idle/processing size; the window is exactly this big. */
    val circleSizePx: Int = circlePx.toInt()

    /** Window size while listening: a pill with waveform and a stop button. */
    val pillWidthPx: Int = (circlePx * PILL_RATIO).toInt()

    var expanded = false
        private set

    val widthPx: Int get() = if (expanded) pillWidthPx else circleSizePx

    private val dark = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
        Configuration.UI_MODE_NIGHT_YES

    // Material You tones: 600/0 on light, 200/900 on dark.
    private val accent = context.getColor(if (dark) android.R.color.system_accent1_200 else android.R.color.system_accent1_600)
    private val onAccent = context.getColor(if (dark) android.R.color.system_accent1_900 else android.R.color.system_accent1_0)
    private val errorBg = if (dark) 0xFFF2B8B5.toInt() else 0xFFB3261E.toInt()
    private val onError = if (dark) 0xFF601410.toInt() else 0xFFFFFFFF.toInt()

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private val rect = RectF()
    private val micIcon: Drawable = requireNotNull(context.getDrawable(R.drawable.ic_bubble_mic)).mutate()
    private val checkIcon: Drawable = requireNotNull(context.getDrawable(R.drawable.ic_bubble_check)).mutate()
    private val errorIcon: Drawable = requireNotNull(context.getDrawable(R.drawable.ic_bubble_error)).mutate()

    private var phase = BubblePhase.IDLE
    private var spin = 0f

    /** Recent input levels, newest last, drawn as the waveform. */
    private val levels = FloatArray(BARS)

    private val spinner = ValueAnimator.ofFloat(0f, 360f).apply {
        duration = 900
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener {
            spin = it.animatedValue as Float
            invalidate()
        }
    }

    // Gesture state.
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private val main = Handler(Looper.getMainLooper())
    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var dragging = false
    private var holding = false
    private val holdRunnable = Runnable {
        holding = true
        performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        listener?.onHoldStart()
    }

    init {
        isClickable = true
        accessibilityLiveRegion = ACCESSIBILITY_LIVE_REGION_POLITE
        contentDescription = describe(BubblePhase.IDLE)
        // TalkBack double-tap lands in performClick (toggle); this adds a way to discard.
        ViewCompat.addAccessibilityAction(this, context.getString(R.string.bubble_action_cancel)) { _, _ ->
            listener?.onCancel()
            true
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(widthPx, circleSizePx)
    }

    fun setPhase(next: BubblePhase, level: Float = 0f) {
        val wantExpanded = next == BubblePhase.LISTENING
        if (next == BubblePhase.LISTENING) {
            System.arraycopy(levels, 1, levels, 0, BARS - 1)
            levels[BARS - 1] = level.coerceIn(0f, 1f)
        }
        if (next == phase) {
            if (next == BubblePhase.LISTENING) invalidate()
            return
        }
        phase = next
        if (next == BubblePhase.PROCESSING) {
            if (!spinner.isStarted) spinner.start()
        } else if (spinner.isStarted) {
            spinner.cancel()
        }
        if (next != BubblePhase.LISTENING) levels.fill(0f)
        if (wantExpanded != expanded) {
            expanded = wantExpanded
            requestLayout()
        }
        val description = describe(next)
        contentDescription = description
        stateDescription = description
        invalidate()
    }

    private fun describe(p: BubblePhase): String = context.getString(
        when (p) {
            BubblePhase.IDLE -> R.string.bubble_desc_idle
            BubblePhase.LISTENING -> R.string.bubble_desc_listening
            BubblePhase.PROCESSING -> R.string.bubble_desc_processing
            BubblePhase.DONE -> R.string.bubble_desc_done
            BubblePhase.ERROR -> R.string.bubble_desc_error
        },
    )

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        val error = phase == BubblePhase.ERROR

        fill.color = if (error) errorBg else accent
        rect.set(0f, 0f, w, h)
        canvas.drawRoundRect(rect, h / 2, h / 2, fill)

        if (expanded) drawPill(canvas, w, h) else drawCircleContent(canvas, w, h, error)
    }

    private fun drawCircleContent(canvas: Canvas, w: Float, h: Float, error: Boolean) {
        if (phase == BubblePhase.PROCESSING) {
            stroke.color = onAccent
            stroke.strokeWidth = 3 * density
            val r = h / 2 - 4 * density
            rect.set(w / 2 - r, h / 2 - r, w / 2 + r, h / 2 + r)
            canvas.drawArc(rect, spin, 100f, false, stroke)
        }
        val icon = when (phase) {
            BubblePhase.DONE -> checkIcon
            BubblePhase.ERROR -> errorIcon
            else -> micIcon
        }
        icon.setTint(if (error) onError else onAccent)
        val half = (h * 0.28f).toInt()
        icon.setBounds((w / 2 - half).toInt(), (h / 2 - half).toInt(), (w / 2 + half).toInt(), (h / 2 + half).toInt())
        icon.draw(canvas)
    }

    /** Waveform on the left, stop button on the right. */
    private fun drawPill(canvas: Canvas, w: Float, h: Float) {
        val pad = h * 0.3f
        val stopSize = h * 0.62f
        val stopLeft = w - pad * 0.5f - stopSize
        // Waveform bars.
        val left = pad
        val right = stopLeft - pad * 0.6f
        val slot = (right - left) / BARS
        fill.color = onAccent
        val barWidth = slot * 0.5f
        for (i in 0 until BARS) {
            val bar = (0.12f + 0.88f * levels[i]) * (h * 0.56f)
            val cx = left + slot * (i + 0.5f)
            rect.set(cx - barWidth / 2, h / 2 - bar / 2, cx + barWidth / 2, h / 2 + bar / 2)
            canvas.drawRoundRect(rect, barWidth / 2, barWidth / 2, fill)
        }
        // Stop button: a lighter disc with a rounded square.
        fill.color = (onAccent and 0x00FFFFFF) or 0x33000000
        val cx = stopLeft + stopSize / 2
        canvas.drawCircle(cx, h / 2, stopSize / 2, fill)
        fill.color = onAccent
        val q = stopSize * 0.2f
        rect.set(cx - q, h / 2 - q, cx + q, h / 2 + q)
        canvas.drawRoundRect(rect, q * 0.3f, q * 0.3f, fill)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.rawX
                downY = event.rawY
                lastX = downX
                lastY = downY
                dragging = false
                holding = false
                listener?.onPress()
                // No hold-to-talk while a session is already running; the pill is a stop button.
                if (!expanded) main.postDelayed(holdRunnable, ViewConfiguration.getLongPressTimeout().toLong())
            }
            MotionEvent.ACTION_MOVE -> {
                if (!holding && !dragging && (abs(event.rawY - downY) > slop || abs(event.rawX - downX) > slop)) {
                    dragging = true
                    main.removeCallbacks(holdRunnable)
                    listener?.onDragStart()
                }
                if (dragging) {
                    listener?.onDrag(event.rawX - lastX, event.rawY - lastY)
                    lastX = event.rawX
                    lastY = event.rawY
                }
            }
            MotionEvent.ACTION_UP -> {
                main.removeCallbacks(holdRunnable)
                when {
                    holding -> listener?.onHoldEnd()
                    dragging -> listener?.onDragEnd()
                    else -> {
                        performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                        performClick()
                    }
                }
                listener?.onReleased()
            }
            MotionEvent.ACTION_CANCEL -> {
                main.removeCallbacks(holdRunnable)
                if (holding) listener?.onHoldEnd() else if (dragging) listener?.onDragEnd()
                listener?.onReleased()
            }
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        listener?.onTap()
        return true
    }

    /** Haptic for state changes and docking; follows the system touch-feedback setting. */
    fun buzz(kind: Int) {
        performHapticFeedback(kind)
    }

    override fun onDetachedFromWindow() {
        spinner.cancel()
        main.removeCallbacks(holdRunnable)
        super.onDetachedFromWindow()
    }

    companion object {
        private const val PILL_RATIO = 3.6f
        private const val BARS = 7
    }
}
