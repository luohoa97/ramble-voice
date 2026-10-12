// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Microphone capture for `ramble/audio` and `ramble/audio/pcm`.
 *
 * Dart first listens to the PCM event channel, then calls `start`. Audio is
 * 16 kHz mono PCM16 from the VOICE_RECOGNITION source, read on a background
 * thread in ~30 ms blocks and posted to the main thread for the event sink.
 * `stop` ends the stream once the last block has been delivered.
 *
 * Usable from any engine (Activity or keyboard); only one capture runs at a
 * time per process.
 */
class AudioCaptureHandler(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, "ramble/audio")
    private val events = EventChannel(messenger, "ramble/audio/pcm")

    private var sink: EventChannel.EventSink? = null

    @Volatile private var thread: Thread? = null
    @Volatile private var running = false

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun dispose() {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        stopCapture()
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> result.success(hasPermission())
            "start" -> result.success(startCapture())
            "stop" -> {
                stopCapture()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        stopCapture()
        sink = null
    }

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun startCapture(): Boolean {
        if (running) return true
        if (!hasPermission() || sink == null) return false
        // A previous capture may still be draining its last block.
        thread?.let {
            it.join(300)
            if (it.isAlive) return false
        }

        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) return false

        val record = try {
            AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                        .build(),
                )
                // Half a second of headroom so a busy main thread never drops audio.
                .setBufferSizeInBytes(maxOf(minBuffer, SAMPLE_RATE))
                .build()
        } catch (e: SecurityException) {
            return false
        } catch (e: UnsupportedOperationException) {
            return false
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return false
        }
        try {
            record.startRecording()
        } catch (e: IllegalStateException) {
            record.release()
            return false
        }

        running = true
        thread = Thread({ readLoop(record) }, "ramble-audio").also { it.start() }
        return true
    }

    private fun readLoop(record: AudioRecord) {
        val buffer = ByteArray(BLOCK_BYTES)
        try {
            while (running) {
                val n = record.read(buffer, 0, buffer.size)
                if (n > 0) {
                    val block = buffer.copyOf(n)
                    main.post { sink?.success(block) }
                } else if (n < 0) {
                    break
                }
            }
        } finally {
            try {
                record.stop()
            } catch (_: IllegalStateException) {
            }
            record.release()
            running = false
            // Posted after the last block so the stream closes only once drained.
            main.post {
                sink?.endOfStream()
                sink = null
            }
        }
    }

    private fun stopCapture() {
        // Do not join on the main thread; the loop exits within one block.
        running = false
    }

    companion object {
        const val SAMPLE_RATE = 16000
        // 30 ms of 16-bit mono.
        private const val BLOCK_BYTES = SAMPLE_RATE * 30 / 1000 * 2
    }
}
