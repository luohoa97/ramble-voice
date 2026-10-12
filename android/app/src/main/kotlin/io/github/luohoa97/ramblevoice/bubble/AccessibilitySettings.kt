// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice.bubble

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.Settings

/**
 * Opens the system page where the user turns the floating mic on.
 *
 * The per-service details page (android.settings.ACCESSIBILITY_DETAILS_SETTINGS)
 * needs a permission only system apps hold, so normal apps get a
 * SecurityException. Use the main Accessibility list instead, with the
 * extras Settings uses to scroll to and highlight an entry.
 */
object AccessibilitySettings {
    private const val EXTRA_FRAGMENT_ARG_KEY = ":settings:fragment_args_key"
    private const val EXTRA_SHOW_FRAGMENT_ARGUMENTS = ":settings:show_fragment_args"

    fun intent(context: Context): Intent {
        val key = ComponentName(context, RambleBubbleService::class.java).flattenToString()
        return Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
            putExtra(EXTRA_FRAGMENT_ARG_KEY, key)
            putExtra(EXTRA_SHOW_FRAGMENT_ARGUMENTS, Bundle().apply { putString(EXTRA_FRAGMENT_ARG_KEY, key) })
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }

    fun open(context: Context) {
        try {
            context.startActivity(intent(context))
        } catch (_: Exception) {
            context.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }
}
