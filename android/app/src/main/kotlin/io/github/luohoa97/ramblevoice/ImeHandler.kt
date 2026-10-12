// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.content.Intent
import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `ramble/ime` (keyboard engine only). Dart to native: text commits, key
 * actions and navigation. Native to Dart: `inputStarted`, `inputFinished` and
 * `release`.
 */
class ImeHandler(
    private val service: InputMethodService,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "ramble/ime")

    init {
        channel.setMethodCallHandler(this)
        ImeLaunch.stopListener = { channel.invokeMethod("stopListening", null) }
    }

    fun dispose() {
        ImeLaunch.stopListener = null
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "commitText" -> {
                val text = call.arguments as? String ?: call.argument<String>("text") ?: ""
                result.success(service.currentInputConnection?.commitText(text, 1) ?: false)
            }
            "deleteBackward" -> {
                val count = call.arguments as? Int ?: call.argument<Int>("count") ?: 1
                result.success(deleteBackward(count))
            }
            "getSelectedText" -> {
                val text = service.currentInputConnection?.getSelectedText(0)?.toString()
                result.success(if (text.isNullOrEmpty()) null else text)
            }
            "getTextBeforeCursor" -> {
                val count = (call.arguments as? Int ?: call.argument<Int>("count") ?: 0).coerceIn(0, MAX_READ)
                result.success(service.currentInputConnection?.getTextBeforeCursor(count, 0)?.toString())
            }
            "getTextAfterCursor" -> {
                val count = (call.arguments as? Int ?: call.argument<Int>("count") ?: 0).coerceIn(0, MAX_READ)
                result.success(service.currentInputConnection?.getTextAfterCursor(count, 0)?.toString())
            }
            "replaceSelection" -> {
                val text = call.arguments as? String ?: call.argument<String>("text") ?: ""
                result.success(replaceSelection(text))
            }
            "replaceBeforeCursor" -> {
                result.success(
                    replaceBeforeCursor(
                        call.argument<Int>("length") ?: 0,
                        call.argument<String>("text") ?: "",
                        call.argument<String>("expected"),
                    ),
                )
            }
            "sendEnter" -> result.success(sendEnter())
            "switchToPreviousInputMethod" -> result.success(switchKeyboard(userInitiated = call.arguments as? Boolean ?: true))
            "shouldOfferSwitch" -> result.success(shouldOfferSwitch())
            "openApp" -> {
                openApp(call.arguments as? String ?: call.argument<String>("route"))
                result.success(null)
            }
            "hideKeyboard" -> {
                service.requestHideSelf(0)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun deleteBackward(count: Int): Boolean {
        val ic = service.currentInputConnection ?: return false
        if (count <= 1) {
            // Same path hardware/IME backspace takes; works in WebViews and
            // terminals that ignore deleteSurroundingText.
            service.sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL)
            return true
        }
        return ic.deleteSurroundingTextInCodePoints(count, 0)
    }

    /** Replaces the selection (commitText over a selection replaces it). */
    private fun replaceSelection(text: String): Boolean {
        val ic = service.currentInputConnection ?: return false
        val selected = ic.getSelectedText(0)
        if (selected.isNullOrEmpty()) return false
        return ic.commitText(text, 1)
    }

    /**
     * Replaces the [length] UTF-16 units before the cursor with [text]. If
     * [expected] is given the text before the cursor must still end with it,
     * otherwise nothing is touched. Done in one batch so the field never shows
     * the text half deleted.
     */
    private fun replaceBeforeCursor(length: Int, text: String, expected: String?): Boolean {
        val ic = service.currentInputConnection ?: return false
        if (length <= 0 || length > MAX_READ) return false
        // A selection means the cursor is not where the old text ends.
        if (!ic.getSelectedText(0).isNullOrEmpty()) return false
        val before = ic.getTextBeforeCursor(length, 0)?.toString() ?: return false
        if (before.length != length) return false
        if (expected != null && before != expected) return false
        ic.beginBatchEdit()
        try {
            if (!ic.deleteSurroundingText(length, 0)) return false
            return ic.commitText(text, 1)
        } finally {
            ic.endBatchEdit()
        }
    }

    private fun sendEnter(): Boolean {
        val ic = service.currentInputConnection ?: return false
        val info = service.currentInputEditorInfo
        val options = info?.imeOptions ?: 0
        val action = options and EditorInfo.IME_MASK_ACTION
        val noEnterAction = options and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0
        if (!noEnterAction &&
            action != EditorInfo.IME_ACTION_NONE &&
            action != EditorInfo.IME_ACTION_UNSPECIFIED
        ) {
            return ic.performEditorAction(action)
        }
        service.sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER)
        return true
    }

    /**
     * Returns to the user's typing keyboard. Order: the system's "previous"
     * keyboard, then Gboard, then any other enabled real keyboard. The picker
     * appears only when no other keyboard exists, so the automatic hop back
     * after dictation never pops a dialog under the user's finger.
     */
    /**
     * Returns to the user's typing keyboard: the system's "previous" keyboard,
     * else Gboard, else any other enabled keyboard that is not voice-only.
     * [userInitiated] only matters when nothing qualifies: then the explicit
     * switch key shows the picker, while the automatic hop back after a
     * dictation stays silent (never a dialog under the user's finger).
     */
    private fun switchKeyboard(userInitiated: Boolean): Boolean {
        if (service.switchToPreviousInputMethod()) return true
        val target = typingKeyboardId()
        if (target != null) {
            service.switchInputMethod(target)
            return true
        }
        if (userInitiated) {
            service.getSystemService(InputMethodManager::class.java)?.showInputMethodPicker()
        }
        return false
    }

    private fun typingKeyboardId(): String? {
        val imm = service.getSystemService(InputMethodManager::class.java) ?: return null
        val own = service.packageName
        val candidates = imm.enabledInputMethodList.filter { info ->
            info.packageName != own && !isVoiceOnly(info)
        }
        return (candidates.firstOrNull { it.packageName == GBOARD } ?: candidates.firstOrNull())?.id
    }

    /** Voice helpers (e.g. Google voice typing) declare only voice subtypes. */
    private fun isVoiceOnly(info: android.view.inputmethod.InputMethodInfo): Boolean {
        val count = info.subtypeCount
        return count > 0 && (0 until count).all { info.getSubtypeAt(it).mode == "voice" }
    }

    private fun shouldOfferSwitch(): Boolean {
        val imm = service.getSystemService(InputMethodManager::class.java) ?: return false
        val token = service.window?.window?.attributes?.token ?: return false
        return imm.shouldOfferSwitchingToNextInputMethod(token)
    }

    private fun openApp(route: String?) {
        val intent = Intent(service, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            if (!route.isNullOrEmpty()) putExtra(MainActivity.EXTRA_ROUTE, route)
        }
        service.startActivity(intent)
        service.requestHideSelf(0)
    }

    companion object {
        private const val GBOARD = "com.google.android.inputmethod.latin"
        /** Upper bound for text read from or replaced in the field. */
        private const val MAX_READ = 20000
    }

    fun notifyInputStarted(info: EditorInfo?, restarting: Boolean) {
        val inputType = info?.inputType ?: 0
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        val cls = inputType and InputType.TYPE_MASK_CLASS
        val isPassword = (cls == InputType.TYPE_CLASS_TEXT &&
            (variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)) ||
            (cls == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD)
        val options = info?.imeOptions ?: 0
        // Set when the floating mic switched to this keyboard to dictate.
        val autoStartHold = ImeLaunch.consumeAutoStart()
        channel.invokeMethod(
            "inputStarted",
            mapOf(
                "autoStart" to (autoStartHold != null),
                "hold" to (autoStartHold == true),
                "inputType" to inputType,
                "imeOptions" to options,
                "actionId" to (options and EditorInfo.IME_MASK_ACTION),
                "actionLabel" to info?.actionLabel?.toString(),
                "packageName" to info?.packageName,
                "isPassword" to isPassword,
                "multiLine" to (inputType and InputType.TYPE_TEXT_FLAG_MULTI_LINE != 0),
                "restarting" to restarting,
            ),
        )
    }

    fun notifyInputFinished() {
        channel.invokeMethod("inputFinished", null)
    }

    /** Asks Dart to free the on-device model, then runs [done] (always, even on error). */
    fun requestRelease(done: () -> Unit) {
        channel.invokeMethod("release", null, object : MethodChannel.Result {
            override fun success(result: Any?) = done()
            override fun error(code: String, message: String?, details: Any?) = done()
            override fun notImplemented() = done()
        })
    }
}
