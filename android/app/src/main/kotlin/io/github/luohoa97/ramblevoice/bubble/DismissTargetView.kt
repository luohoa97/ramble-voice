// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice.bubble

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View

/**
 * The drop target shown at the bottom centre while the bubble is dragged.
 * Draws a circle with a cross; once the bubble has hovered long enough it is
 * [armed] and says it will hide the bubble for the whole app. Never takes touches.
 */
class DismissTargetView(context: Context) : View(context) {
    private val density = resources.displayMetrics.density

    /** Window size: the circle plus room for the label underneath. */
    val widthPx = (176 * density).toInt()
    val heightPx = (112 * density).toInt()
    val radiusPx = 32 * density

    /** Circle centre inside this view. */
    val centerX get() = widthPx / 2f
    val centerY get() = 40 * density

    /** Bubble is over the target. */
    var hot = false
        set(value) {
            if (field == value) return
            field = value
            animate().scaleX(if (value) 1.15f else 1f).scaleY(if (value) 1.15f else 1f).setDuration(120).start()
            invalidate()
        }

    /** Held over the target long enough to hide for this app. */
    var armed = false
        set(value) {
            if (field == value) return
            field = value
            invalidate()
        }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFFFFFF.toInt()
        textSize = 13 * density
        textAlign = Paint.Align.CENTER
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(widthPx, heightPx)
    }

    override fun onDraw(canvas: Canvas) {
        paint.style = Paint.Style.FILL
        paint.color = if (hot) 0xFFB3261E.toInt() else 0xCC202124.toInt()
        canvas.drawCircle(centerX, centerY, radiusPx, paint)
        paint.style = Paint.Style.STROKE
        paint.color = 0xFFFFFFFF.toInt()
        paint.strokeWidth = 3 * density
        paint.strokeCap = Paint.Cap.ROUND
        val a = radiusPx * 0.35f
        canvas.drawLine(centerX - a, centerY - a, centerX + a, centerY + a, paint)
        canvas.drawLine(centerX - a, centerY + a, centerX + a, centerY - a, paint)
        val label = when {
            armed -> "Hide in this app"
            hot -> "Hold to hide in this app"
            else -> null
        }
        if (label != null) canvas.drawText(label, centerX, centerY + radiusPx + 20 * density, text)
    }
}
