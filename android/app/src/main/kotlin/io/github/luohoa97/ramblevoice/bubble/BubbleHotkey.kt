// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice.bubble

import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent

/**
 * The physical-keyboard dictation key. Only the configured key's code is ever
 * compared; no other key data is read, stored, logged or forwarded.
 *
 * "Record a key" is a one-shot, user-initiated capture of a single key code
 * from the settings screen; it times out and is never left armed.
 */
object BubbleHotkey {
    const val DEFAULT_CODE = KeyEvent.KEYCODE_CAPS_LOCK
    private const val RECORD_TIMEOUT_MS = 10_000L

    private var recorder: ((Int) -> Unit)? = null
    private var recordUntil = 0L

    /** Arms [onKey] to receive the next key code the user presses. */
    @Synchronized
    fun record(onKey: (Int) -> Unit) {
        recorder = onKey
        recordUntil = SystemClock.uptimeMillis() + RECORD_TIMEOUT_MS
    }

    @Synchronized
    fun cancelRecording() {
        recorder = null
    }

    /** True while a recording is armed. */
    @Synchronized
    fun isRecording(): Boolean = recorder != null && SystemClock.uptimeMillis() <= recordUntil

    /** Hands [code] to the armed recorder, once. */
    @Synchronized
    fun deliver(code: Int): Boolean {
        val r = recorder ?: return false
        recorder = null
        if (SystemClock.uptimeMillis() > recordUntil) return false
        r(code)
        return true
    }

    /** Keys that must keep working while recording, so the user can never get stuck. */
    fun isSystemKey(code: Int) = code == KeyEvent.KEYCODE_BACK || code == KeyEvent.KEYCODE_HOME ||
        code == KeyEvent.KEYCODE_APP_SWITCH || code == KeyEvent.KEYCODE_POWER

    /** A connected, real alphabetic keyboard (not the soft keyboard). */
    fun isHardwareKeyboard(deviceId: Int): Boolean {
        val d = InputDevice.getDevice(deviceId) ?: return false
        return !d.isVirtual && d.supportsSource(InputDevice.SOURCE_KEYBOARD) &&
            d.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC
    }
}
