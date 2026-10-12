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

    /** Vertical drag offset from the default position, in dp. */
    var offsetYDp: Float
        get() = prefs.getFloat(KEY_OFFSET_Y, 0f)
        set(value) = prefs.edit().putFloat(KEY_OFFSET_Y, value).apply()

    fun setConfig(blocked: Collection<String>, size: String) {
        prefs.edit()
            .putStringSet(KEY_BLOCKED, blocked.toSet())
            .putString(KEY_SIZE, size)
            .apply()
    }

    companion object {
        const val NAME = "ramble_bubble"
        private const val KEY_BLOCKED = "blocked"
        private const val KEY_AUTO_RESTORE = "auto_restore"
        private const val KEY_WANTED = "wanted"
        private const val KEY_SIZE = "size"
        private const val KEY_OFFSET_Y = "offset_y_dp"
        const val SIZE_SMALL_DP = 40
        const val SIZE_MEDIUM_DP = 52
    }
}
