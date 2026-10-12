// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.os.SystemClock

/**
 * Hand-off between the floating mic ([io.github.luohoa97.ramblevoice.bubble.RambleBubbleService])
 * and the Ramble keyboard. Both live in this process, so plain statics do.
 *
 * The bubble asks for an auto-start, switches the keyboard to Ramble, and the
 * keyboard's next `onStartInputView` consumes the request and starts listening.
 * A request that is not consumed within [TTL_MS] is dropped, so a failed switch
 * can never make the keyboard start recording later on its own.
 */
object ImeLaunch {
    private const val TTL_MS = 3000L

    private var expiresAt = 0L
    private var hold = false

    /** True while the Ramble keyboard is the active keyboard with its input view up. */
    @Volatile var imeShowing = false
        private set

    /** Bubble side: called when [imeShowing] changes. */
    @Volatile var onImeShowingChanged: (() -> Unit)? = null

    /** Keyboard side: forwards a hold-to-talk release to Dart as `stopListening`. */
    @Volatile var stopListener: (() -> Unit)? = null

    @Synchronized
    fun requestAutoStart(holdToTalk: Boolean) {
        expiresAt = SystemClock.uptimeMillis() + TTL_MS
        hold = holdToTalk
    }

    /** Returns null when no valid request is pending, else whether it is hold-to-talk. Clears the request. */
    @Synchronized
    fun consumeAutoStart(): Boolean? {
        val valid = expiresAt != 0L && SystemClock.uptimeMillis() <= expiresAt
        val result = if (valid) hold else null
        expiresAt = 0L
        return result
    }

    /** True if an unexpired auto-start request is waiting (does not consume it). */
    @Synchronized
    fun hasPendingAutoStart(): Boolean = expiresAt != 0L && SystemClock.uptimeMillis() <= expiresAt

    /** Bubble side: the user released a hold-to-talk that started the keyboard. */
    fun requestStop() {
        stopListener?.invoke()
    }

    fun setImeShowing(showing: Boolean) {
        if (imeShowing == showing) return
        imeShowing = showing
        onImeShowingChanged?.invoke()
    }
}
