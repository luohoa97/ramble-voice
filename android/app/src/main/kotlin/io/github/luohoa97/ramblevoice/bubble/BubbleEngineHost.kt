// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice.bubble

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.luohoa97.ramblevoice.AudioCaptureHandler
import io.github.luohoa97.ramblevoice.RambleApplication
import io.github.luohoa97.ramblevoice.SystemHandler

/**
 * The headless Flutter engine that runs dictation (`bubbleMain`, no
 * FlutterView) and the `ramble/bubble` channel to it. Started lazily, kept
 * warm by the service.
 *
 * Commands sent before Dart reports `ready` are queued (only the latest one;
 * a user cannot meaningfully queue two taps).
 */
class BubbleEngineHost(
    private val context: Context,
    private val hapticView: () -> View?,
    private val listener: Listener,
) {
    interface Listener {
        fun onState(phase: BubblePhase, level: Float, message: String?)

        /** Dart wants [text] inserted; call [reply] with whether it reached the field. */
        fun onInsert(text: String, reply: (Boolean) -> Unit)
    }

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var audio: AudioCaptureHandler? = null
    private var system: SystemHandler? = null
    private var ready = false
    private var pending: Pair<String, Any?>? = null
    private val main = Handler(Looper.getMainLooper())

    val isStarted: Boolean get() = engine != null
    val isReady: Boolean get() = ready

    /** Starts the engine if needed. Cheap when already running. */
    fun ensureStarted() {
        if (engine != null) return
        val e = (context.applicationContext as RambleApplication).createBubbleEngine(context)
        val messenger = e.dartExecutor.binaryMessenger
        audio = AudioCaptureHandler(context.applicationContext, messenger)
        system = SystemHandler(context, messenger, hapticView)
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler { call, result -> onCall(call, result) } }
        e.lifecycleChannel.appIsResumed()
        engine = e
    }

    /** Sends [method] to Dart, or queues it until Dart is ready. */
    fun send(method: String, args: Any? = null) {
        ensureStarted()
        if (!ready) {
            pending = method to args
            return
        }
        channel?.invokeMethod(method, args)
    }

    /** Fire-and-forget, only if the engine is already up (never starts it). */
    fun sendIfRunning(method: String, args: Any? = null) {
        if (ready) channel?.invokeMethod(method, args)
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ready" -> {
                ready = true
                pending?.let { (method, args) -> channel?.invokeMethod(method, args) }
                pending = null
                result.success(null)
            }
            "state" -> {
                val phase = when (call.argument<String>("phase")) {
                    "listening" -> BubblePhase.LISTENING
                    "processing" -> BubblePhase.PROCESSING
                    "done" -> BubblePhase.DONE
                    "error" -> BubblePhase.ERROR
                    else -> BubblePhase.IDLE
                }
                val level = call.argument<Double>("level")?.toFloat() ?: 0f
                listener.onState(phase, level, call.argument<String>("message"))
                result.success(null)
            }
            "insert" -> {
                val text = call.arguments as? String
                if (text.isNullOrEmpty()) result.success(false) else listener.onInsert(text) { result.success(it) }
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        val e = engine ?: return
        engine = null
        ready = false
        pending = null
        channel?.setMethodCallHandler(null)
        channel = null
        audio?.dispose()
        system?.dispose()
        audio = null
        system = null
        main.post {
            e.lifecycleChannel.appIsDetached()
            e.destroy()
        }
    }

    companion object {
        const val CHANNEL = "ramble/bubble"
    }
}
