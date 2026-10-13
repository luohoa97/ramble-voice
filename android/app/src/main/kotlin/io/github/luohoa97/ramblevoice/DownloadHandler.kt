// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * `ramble/download` (control) and `ramble/download/progress` (live updates).
 * The transfer itself runs in [ModelDownloadService]; this only forwards
 * commands and reports what [DownloadRegistry] and the disk say.
 */
class DownloadHandler(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val channel = MethodChannel(messenger, "ramble/download")
    private val events = EventChannel(messenger, "ramble/download/progress")
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        DownloadRegistry.listener = null
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        DownloadRegistry.listener = { fileName, snapshot ->
            main.post { sink.success(snapshot.toMap(fileName)) }
        }
    }

    override fun onCancel(arguments: Any?) {
        DownloadRegistry.listener = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> {
                    val url = call.argument<String>("url")
                    val fileName = call.argument<String>("fileName")
                    val sha = call.argument<String>("sha256")
                    val size = call.argument<Number>("sizeBytes")?.toLong()
                    val title = call.argument<String>("title")
                    if (url == null || fileName == null || sha == null || size == null || title == null) {
                        result.error("bad_args", "url, fileName, sha256, sizeBytes and title are required", null)
                        return
                    }
                    modelsDir()
                    context.startForegroundService(
                        ModelDownloadService.intentFor(context, ModelDownloadService.ACTION_START, url, fileName, sha, size, title),
                    )
                    result.success(null)
                }
                "pause", "cancel" -> {
                    // The service reads the full parameter set from its own state; a bare
                    // intent is enough because only fileName is compared.
                    val fileName = call.argument<String>("fileName")
                    if (fileName == null) {
                        result.error("bad_args", "fileName is required", null)
                        return
                    }
                    val action = if (call.method == "pause") ModelDownloadService.ACTION_PAUSE else ModelDownloadService.ACTION_CANCEL
                    context.startService(
                        ModelDownloadService.intentFor(context, action, "", fileName, "", 1, ""),
                    )
                    result.success(null)
                }
                "status" -> {
                    val fileName = call.argument<String>("fileName")
                    if (fileName == null) {
                        result.error("bad_args", "fileName is required", null)
                        return
                    }
                    result.success(status(fileName))
                }
                "modelsDir" -> result.success(modelsDir().absolutePath)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("download_error", e.message, null)
        }
    }

    private fun modelsDir(): File {
        val base = context.getExternalFilesDir(null) ?: throw IllegalStateException("External storage is unavailable")
        return File(base, "models").also { it.mkdirs() }
    }

    private fun status(fileName: String): Map<String, Any?> {
        DownloadRegistry.get(fileName)?.let { return it.toMap(fileName) }
        val dir = modelsDir()
        val done = File(dir, fileName)
        val part = File(dir, "$fileName.part")
        return when {
            done.exists() -> DownloadSnapshot("done", done.length(), done.length())
            part.exists() -> DownloadSnapshot("paused", DownloadSegments.downloadedBytes(part))
            else -> DownloadSnapshot("idle")
        }.toMap(fileName)
    }
}
