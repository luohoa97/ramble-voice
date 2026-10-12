// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice.bubble

import android.content.Context
import android.content.SharedPreferences

/**
 * Native mirror of the bubble settings. The Dart settings file is the source
 * of truth, but the accessibility service must not wait for a Flutter engine
 * to decide whether to show, so the app pushes these over `ramble/system`.
 */
class BubblePrefs(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    val blockedApps: Set<String>
        get() = prefs.getStringSet(KEY_BLOCKED, emptySet()) ?: emptySet()

    /** The user has the bubble on; the keeper warns if it later goes off. */
    var wanted: Boolean
        get() = prefs.getBoolean(KEY_WANTED, false)
        set(value) = prefs.edit().putBoolean(KEY_WANTED, value).apply()

    /** Opt-in: re-enable the service when the system turns it off. Off by default. */
    var autoRestore: Boolean
        get() = prefs.getBoolean(KEY_AUTO_RESTORE, false)
        set(value) = prefs.edit().putBoolean(KEY_AUTO_RESTORE, value).apply()

    /** Circle diameter in dp. */
    val sizeDp: Int
        get() = if (prefs.getString(KEY_SIZE, "medium") == "small") SIZE_SMALL_DP else SIZE_MEDIUM_DP

    /** Docked to the right screen edge (else the left). */
    var dockRight: Boolean
        get() = prefs.getBoolean(KEY_DOCK_RIGHT, true)
        set(value) = prefs.edit().putBoolean(KEY_DOCK_RIGHT, value).apply()

    /** Vertical centre as a fraction of screen height, remembered per orientation. */
    fun yFraction(landscape: Boolean): Float = prefs.getFloat(yKey(landscape), DEFAULT_Y_FRACTION)

    fun setYFraction(landscape: Boolean, value: Float) {
        prefs.edit().putFloat(yKey(landscape), value).apply()
    }

    private fun yKey(landscape: Boolean) = if (landscape) KEY_Y_LANDSCAPE else KEY_Y_PORTRAIT

    /** Apps where the user dragged the bubble onto the dismiss target and held it. */
    val hiddenApps: Set<String>
        get() = prefs.getStringSet(KEY_HIDDEN, emptySet()) ?: emptySet()

    fun hideInApp(pkg: String) {
        prefs.edit().putStringSet(KEY_HIDDEN, hiddenApps + pkg).apply()
    }

    fun clearHiddenApps() {
        prefs.edit().remove(KEY_HIDDEN).apply()
    }

    /** Physical-keyboard dictation key on/off. */
    val hotkeyEnabled: Boolean
        get() = prefs.getBoolean(KEY_HOTKEY_ON, true)

    /** Android key code of the dictation key. */
    val hotkeyCode: Int
        get() = prefs.getInt(KEY_HOTKEY_CODE, BubbleHotkey.DEFAULT_CODE)

    fun setConfig(blocked: Collection<String>, size: String, hotkeyEnabled: Boolean = true, hotkeyCode: Int = BubbleHotkey.DEFAULT_CODE) {
        prefs.edit()
            .putBoolean(KEY_HOTKEY_ON, hotkeyEnabled)
            .putInt(KEY_HOTKEY_CODE, hotkeyCode)
            .putStringSet(KEY_BLOCKED, blocked.toSet())
            .putString(KEY_SIZE, size)
            .apply()
    }

    companion object {
        const val NAME = "ramble_bubble"
        private const val KEY_BLOCKED = "blocked"
        private const val KEY_AUTO_RESTORE = "auto_restore"
        private const val KEY_WANTED = "wanted"
        private const val KEY_HOTKEY_ON = "hotkey_on"
        private const val KEY_HOTKEY_CODE = "hotkey_code"
        private const val KEY_SIZE = "size"
        private const val KEY_DOCK_RIGHT = "dock_right"
        private const val KEY_Y_PORTRAIT = "y_portrait"
        private const val KEY_Y_LANDSCAPE = "y_landscape"
        private const val KEY_HIDDEN = "hidden"
        private const val DEFAULT_Y_FRACTION = 0.5f
        const val SIZE_SMALL_DP = 40
        const val SIZE_MEDIUM_DP = 52
    }
}
