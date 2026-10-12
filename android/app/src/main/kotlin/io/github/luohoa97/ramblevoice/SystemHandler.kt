// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.inputmethod.InputMethodManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `ramble/system`: share sheet, dynamic accent colour, haptics and keyboard
 * settings shortcuts. Works from the Activity engine and the keyboard engine;
 * [hapticView] supplies the window view haptics are performed on.
 */
class SystemHandler(
    private val context: Context,
    messenger: BinaryMessenger,
    private val hapticView: () -> View?,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "ramble/system")

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "share" -> {
                share(call.arguments as? String ?: call.argument<String>("text") ?: "")
                result.success(null)
            }
            "openUrl" -> {
                val url = call.arguments as? String ?: call.argument<String>("url")
                val uri = url?.let { android.net.Uri.parse(it) }
                if (uri == null || (uri.scheme != "https" && uri.scheme != "http")) {
                    result.success(false)
                } else {
                    result.success(
                        try {
                            launch(Intent(Intent.ACTION_VIEW, uri))
                            true
                        } catch (e: android.content.ActivityNotFoundException) {
                            false
                        },
                    )
                }
            }
            "accentColor" -> result.success(accentColor())
            "haptic" -> {
                haptic(call.arguments as? String ?: call.argument<String>("kind") ?: "")
                result.success(null)
            }
            "openKeyboardSettings" -> {
                launch(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
                result.success(null)
            }
            "isKeyboardEnabled" -> result.success(isKeyboardEnabled())
            else -> result.notImplemented()
        }
    }

    private fun launch(intent: Intent) {
        if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    private fun share(text: String) {
        if (text.isEmpty()) return
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
        }
        launch(Intent.createChooser(send, context.getString(R.string.share_chooser_title)))
    }

    /** Signed ARGB int of the wallpaper-derived accent, or null before Android 12. */
    private fun accentColor(): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        return context.getColor(android.R.color.system_accent1_500)
    }

    private fun haptic(kind: String) {
        val constant = when (kind) {
            "start" -> HapticFeedbackConstants.LONG_PRESS
            "stop" -> HapticFeedbackConstants.KEYBOARD_TAP
            "done" -> HapticFeedbackConstants.CONFIRM
            "error" -> HapticFeedbackConstants.REJECT
            else -> return
        }
        val view = hapticView()
        if (view != null && view.performHapticFeedback(constant)) return
        // Fall back to a predefined vibration when the view refuses (e.g. the
        // system touch-feedback setting is off but the user still asked for haptics).
        val effect = when (kind) {
            "error" -> VibrationEffect.EFFECT_DOUBLE_CLICK
            "start" -> VibrationEffect.EFFECT_HEAVY_CLICK
            else -> VibrationEffect.EFFECT_TICK
        }
        context.getSystemService(Vibrator::class.java)?.vibrate(VibrationEffect.createPredefined(effect))
    }

    private fun isKeyboardEnabled(): Boolean {
        val imm = context.getSystemService(InputMethodManager::class.java) ?: return false
        return imm.enabledInputMethodList.any { it.packageName == context.packageName }
    }
}
