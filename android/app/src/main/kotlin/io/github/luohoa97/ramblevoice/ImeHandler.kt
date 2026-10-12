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
    }

    fun dispose() {
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
            "sendEnter" -> result.success(sendEnter())
            "switchToPreviousInputMethod" -> result.success(switchKeyboard())
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

    private fun switchKeyboard(): Boolean {
        if (service.switchToPreviousInputMethod()) return true
        // No previous keyboard recorded: let the user pick one.
        service.getSystemService(InputMethodManager::class.java)?.showInputMethodPicker()
        return true
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
        channel.invokeMethod(
            "inputStarted",
            mapOf(
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
