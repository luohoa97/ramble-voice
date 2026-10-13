// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.Manifest
import android.os.Build
import android.os.PowerManager
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.inputmethod.InputMethodManager
import io.github.luohoa97.ramblevoice.bubble.AccessibilitySettings
import io.github.luohoa97.ramblevoice.bubble.BubbleHotkey
import io.github.luohoa97.ramblevoice.bubble.BubbleKeeper
import io.github.luohoa97.ramblevoice.bubble.BubblePrefs
import io.github.luohoa97.ramblevoice.bubble.RambleBubbleService
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
            "contactNames" -> contactNames(result)
            "openKeyboardSettings" -> {
                launch(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
                result.success(null)
            }
            "isKeyboardEnabled" -> result.success(isKeyboardEnabled())
            "isBubbleEnabled" -> result.success(isBubbleEnabled())
            "openBubbleSettings" -> {
                openBubbleSettings()
                result.success(null)
            }
            "openAppDetails" -> {
                launch(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
                result.success(null)
            }
            "setBubbleConfig" -> {
                BubblePrefs(context).setConfig(
                    call.argument<List<String>>("blockedApps") ?: emptyList(),
                    call.argument<String>("size") ?: "medium",
                    call.argument<Boolean>("hotkeyEnabled") ?: true,
                    call.argument<Int>("hotkeyCode") ?: BubbleHotkey.DEFAULT_CODE,
                )
                result.success(null)
            }
            "launchableApps" -> result.success(launchableApps())
            "isIgnoringBattery" ->
                result.success(context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName) == true)
            "requestIgnoreBattery" -> {
                launch(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")))
                result.success(null)
            }
            "manufacturer" -> result.success(Build.MANUFACTURER)
            "recordHotkey" -> {
                // One-shot capture of the next key code, handled by the bubble service.
                if (!BubbleKeeper.isEnabled(context)) {
                    result.success(null)
                } else {
                    val main = android.os.Handler(android.os.Looper.getMainLooper())
                    var answered = false
                    val answer = { code: Int? ->
                        if (!answered) {
                            answered = true
                            result.success(code)
                        }
                    }
                    BubbleHotkey.record { code -> main.post { answer(code) } }
                    main.postDelayed({
                        BubbleHotkey.cancelRecording()
                        answer(null)
                    }, 10_500L)
                }
            }
            "sdkInt" -> result.success(Build.VERSION.SDK_INT)
            "allowBubbleInApp" -> {
                ImeLaunch.allowInOwnApp = call.arguments as? Boolean ?: false
                ImeLaunch.onImeShowingChanged?.invoke()
                result.success(null)
            }
            "hasSecureSettingsPermission" -> result.success(BubbleKeeper.canWriteSecureSettings(context))
            "setBubbleAutoRestore" -> {
                BubblePrefs(context).autoRestore = call.arguments as? Boolean ?: false
                BubbleKeeper.check(context)
                result.success(null)
            }
            "openOemAutostart" -> result.success(openOemAutostart())
            "forgetBubble" -> {
                BubbleKeeper.forget(context)
                result.success(null)
            }
            "appLabel" -> {
                val pkg = call.arguments as? String ?: call.argument<String>("packageName") ?: ""
                result.success(appLabel(pkg))
            }
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

    /**
     * Haptics follow the user's Android setting: View.performHapticFeedback
     * does nothing when system touch feedback is off, and we never override it.
     */
    private fun haptic(kind: String) {
        val constant = when (kind) {
            "start" -> HapticFeedbackConstants.LONG_PRESS
            "stop", "tick" -> HapticFeedbackConstants.KEYBOARD_TAP
            "done" -> HapticFeedbackConstants.CONFIRM
            "error" -> HapticFeedbackConstants.REJECT
            "warn" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                HapticFeedbackConstants.GESTURE_THRESHOLD_ACTIVATE
            } else {
                HapticFeedbackConstants.CONTEXT_CLICK
            }
            "limit" -> HapticFeedbackConstants.LONG_PRESS
            else -> return
        }
        hapticView()?.performHapticFeedback(constant)
    }

    /**
     * Contact display names, or an empty list when READ_CONTACTS is not
     * granted. Queried off the main thread; filtering and de-duplication happen
     * in Dart.
     */
    private fun contactNames(result: MethodChannel.Result) {
        if (context.checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            result.success(emptyList<String>())
            return
        }
        val resolver = context.contentResolver
        val main = Handler(Looper.getMainLooper())
        Thread {
            val names = ArrayList<String>()
            try {
                resolver.query(
                    ContactsContract.Contacts.CONTENT_URI,
                    arrayOf(ContactsContract.Contacts.DISPLAY_NAME_PRIMARY),
                    null,
                    null,
                    null,
                )?.use { c ->
                    while (c.moveToNext()) {
                        c.getString(0)?.let { names.add(it) }
                    }
                }
            } catch (e: Exception) {
                // Permission revoked mid-query or a broken provider: no names.
            }
            main.post { result.success(names) }
        }.start()
    }

    /** The launcher label of [packageName], or the package name itself when it cannot be read. */
    private fun appLabel(packageName: String): String {
        if (packageName.isEmpty()) return packageName
        return try {
            val pm = context.packageManager
            val info = pm.getApplicationInfo(packageName, 0)
            pm.getApplicationLabel(info).toString().ifBlank { packageName }
        } catch (e: Exception) {
            packageName
        }
    }

    private fun isKeyboardEnabled(): Boolean {
        val imm = context.getSystemService(InputMethodManager::class.java) ?: return false
        return imm.enabledInputMethodList.any { it.packageName == context.packageName }
    }

    /** True when the floating-mic accessibility service is switched on. */
    private fun isBubbleEnabled(): Boolean = BubbleKeeper.isEnabled(context)

    private fun openBubbleSettings() {
        AccessibilitySettings.open(context)
    }

    /** Launcher apps (package and label), for the bubble's per-app blocklist. */
    private fun launchableApps(): List<Map<String, String>> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0))
            .map { it.activityInfo.packageName to it.loadLabel(pm).toString() }
            .distinctBy { it.first }
            .filter { it.first != context.packageName }
            .map { mapOf("package" to it.first, "label" to it.second) }
    }

    /**
     * Opens the vendor's app-launch / startup manager (Honor, Huawei, Xiaomi), falling
     * back to this app's details page. Returns true if a vendor screen opened.
     */
    private fun openOemAutostart(): Boolean {
        val screens = listOf(
            ComponentName("com.hihonor.systemmanager", "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
        )
        for (screen in screens) {
            try {
                launch(Intent().setComponent(screen))
                return true
            } catch (e: Exception) {
                // Not this vendor; try the next.
            }
        }
        launch(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
        return false
    }
}
