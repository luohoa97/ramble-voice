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
 * The floating mic. Drawn by hand (circle, icon, level ring, spinner arc) so
 * it stays tiny and has no dependency on Flutter or a theme.
 *
 * Gestures: tap toggles, press and hold is hold-to-talk, dragging moves it
 * vertically. The view reports intent through the callbacks; it never owns
 * dictation state.
 */
class BubbleView(context: Context, private val circleDp: Int) : View(context) {
    interface Listener {
        fun onTap()
        fun onHoldStart()
        fun onHoldEnd()
        fun onCancel()

        /** Finger moved the bubble by [dy] pixels since the last call. */
        fun onDrag(dy: Float)
        fun onDragEnd()
    }

    var listener: Listener? = null

    private val density = resources.displayMetrics.density
    private val circlePx = circleDp * density
    private val ringPad = RING_PAD_DP * density
    val sizePx: Int = (circlePx + ringPad * 2).toInt()

    private val dark = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
        Configuration.UI_MODE_NIGHT_YES

    // Material You tones: 600/0 on light, 200/900 on dark.
    private val accent = context.getColor(if (dark) android.R.color.system_accent1_200 else android.R.color.system_accent1_600)
    private val onAccent = context.getColor(if (dark) android.R.color.system_accent1_900 else android.R.color.system_accent1_0)
    private val errorBg = if (dark) 0xFFF2B8B5.toInt() else 0xFFB3261E.toInt()
    private val onError = if (dark) 0xFF601410.toInt() else 0xFFFFFFFF.toInt()

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 3 * density
        strokeCap = Paint.Cap.ROUND
    }
    private val arcBounds = RectF()
    private val micIcon: Drawable = requireNotNull(context.getDrawable(R.drawable.ic_bubble_mic)).mutate()
    private val checkIcon: Drawable = requireNotNull(context.getDrawable(R.drawable.ic_bubble_check)).mutate()
    private val errorIcon: Drawable = requireNotNull(context.getDrawable(R.drawable.ic_bubble_error)).mutate()

    private var phase = BubblePhase.IDLE
    private var targetLevel = 0f
    private var shownLevel = 0f
    private var spin = 0f

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
    private var downY = 0f
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
        setMeasuredDimension(sizePx, sizePx)
    }

    fun setPhase(next: BubblePhase, level: Float = 0f) {
        targetLevel = level.coerceIn(0f, 1f)
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
        if (next != BubblePhase.LISTENING) {
            targetLevel = 0f
            shownLevel = 0f
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
        val cx = width / 2f
        val cy = height / 2f
        val radius = circlePx / 2f
        val error = phase == BubblePhase.ERROR

        fill.color = if (error) errorBg else accent
        canvas.drawCircle(cx, cy, radius, fill)

        // Level ring: the circle's halo swells with the voice.
        if (phase == BubblePhase.LISTENING) {
            shownLevel += (targetLevel - shownLevel) * 0.35f
            ring.color = (accent and 0x00FFFFFF) or 0xAA000000.toInt()
            ring.strokeWidth = (2f + shownLevel * 4f) * density
            canvas.drawCircle(cx, cy, radius + ringPad * (0.35f + 0.65f * shownLevel), ring)
            if (abs(targetLevel - shownLevel) > 0.01f) postInvalidateOnAnimation()
        }

        // Processing: indeterminate arc hugging the circle.
        if (phase == BubblePhase.PROCESSING) {
            ring.color = accent
            ring.strokeWidth = 3 * density
            val r = radius + ringPad * 0.5f
            arcBounds.set(cx - r, cy - r, cx + r, cy + r)
            canvas.drawArc(arcBounds, spin, 100f, false, ring)
        }

        val icon = when (phase) {
            BubblePhase.DONE -> checkIcon
            BubblePhase.ERROR -> errorIcon
            else -> micIcon
        }
        icon.setTint(if (error) onError else onAccent)
        val half = (circlePx * 0.28f).toInt()
        icon.setBounds((cx - half).toInt(), (cy - half).toInt(), (cx + half).toInt(), (cy + half).toInt())
        icon.draw(canvas)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downY = event.rawY
                lastY = event.rawY
                dragging = false
                holding = false
                main.postDelayed(holdRunnable, ViewConfiguration.getLongPressTimeout().toLong())
            }
            MotionEvent.ACTION_MOVE -> {
                if (!holding && !dragging && abs(event.rawY - downY) > slop) {
                    dragging = true
                    main.removeCallbacks(holdRunnable)
                }
                if (dragging) {
                    listener?.onDrag(event.rawY - lastY)
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
            }
            MotionEvent.ACTION_CANCEL -> {
                main.removeCallbacks(holdRunnable)
                if (holding) listener?.onHoldEnd() else if (dragging) listener?.onDragEnd()
            }
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        listener?.onTap()
        return true
    }

    /** Haptic for state changes: start, confirm and reject. */
    fun buzz(kind: Int) {
        performHapticFeedback(kind)
    }

    override fun onDetachedFromWindow() {
        spinner.cancel()
        main.removeCallbacks(holdRunnable)
        super.onDetachedFromWindow()
    }

    companion object {
        private const val RING_PAD_DP = 8
    }
}
