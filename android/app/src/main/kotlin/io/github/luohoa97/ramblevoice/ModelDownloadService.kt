// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Downloads a model file in the foreground so it keeps going when the app is
 * closed, and shows progress as an Android 16 Live Update (visible on the lock
 * screen). Resumes a `.part` file with HTTP Range, retries with backoff on
 * network loss, and only renames to the final name after the SHA-256 matches.
 */
class ModelDownloadService : Service() {

    private class Params(
        val url: String,
        val fileName: String,
        val sha256: String,
        val sizeBytes: Long,
        val title: String,
    )

    private class Fatal(message: String) : Exception(message)

    private lateinit var notifications: NotificationManager
    private var params: Params? = null
    private var worker: Thread? = null

    @Volatile
    private var stopRequested = false

    @Volatile
    private var cancelRequested = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        notifications = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(CHANNEL_ID, "Model downloads", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Progress of on-device model downloads"
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setShowBadge(false)
        }
        notifications.createNotificationChannel(channel)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val incoming = intent?.let(::readParams)
        if (incoming == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val running = worker?.isAlive == true && params?.fileName == incoming.fileName
        when (intent.action) {
            ACTION_START -> start(incoming)
            ACTION_PAUSE -> if (running) stopWorker(cancel = false) else stopSelfIfIdle(startId)
            ACTION_CANCEL -> if (running) {
                stopWorker(cancel = true)
            } else {
                // Not running (e.g. cancelling from a paused notification).
                discard(incoming)
                stopSelfIfIdle(startId)
            }
        }
        // Redelivered after the process is killed, so a swipe-away does not end the download.
        return START_REDELIVER_INTENT
    }

    private fun start(p: Params) {
        val current = params
        if (worker?.isAlive == true) {
            if (current?.fileName != p.fileName) {
                DownloadRegistry.update(p.fileName, DownloadSnapshot("failed", error = "Another model is already downloading."))
            }
            return
        }
        params = p
        stopRequested = false
        cancelRequested = false
        val existing = partFile(p).let { if (it.exists()) it.length() else 0L }
        startForeground(
            NOTIFICATION_ID,
            progressNotification(p, existing, p.sizeBytes, indeterminate = existing == 0L),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
        DownloadRegistry.update(p.fileName, DownloadSnapshot("running", existing, p.sizeBytes))
        worker = Thread({ run(p) }, "model-download").also { it.start() }
    }

    private fun stopSelfIfIdle(startId: Int) {
        if (worker?.isAlive != true) stopSelf(startId)
    }

    private fun stopWorker(cancel: Boolean) {
        stopRequested = true
        cancelRequested = cancel
        // The worker finishes its current read, then reports through finish().
    }

    /** dataSync services are time limited on Android 15+; keep the partial file and let the user resume. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopWorker(cancel = false)
    }

    // ---- download ----

    private fun run(p: Params) {
        val part = partFile(p)
        var attempt = 0
        try {
            while (!stopRequested) {
                try {
                    transfer(p, part)
                    break
                } catch (e: Fatal) {
                    throw e
                } catch (e: IOException) {
                    if (stopRequested) break
                    if (isOutOfSpace(e)) throw Fatal("Not enough storage space.")
                    DownloadRegistry.update(p.fileName, DownloadSnapshot("retrying", fileLength(part), p.sizeBytes))
                    notify(progressNotification(p, fileLength(part), p.sizeBytes, indeterminate = true, text = "Waiting for network"))
                    sleepInterruptibly(minOf(1000L shl minOf(attempt, 5), 30_000L))
                    attempt++
                }
            }
            if (stopRequested) {
                onStopped(p)
                return
            }
            verifyAndPublish(p, part)
        } catch (e: Fatal) {
            fail(p, part, e.message ?: "The download failed.", deletePart = false)
        } catch (e: Exception) {
            fail(p, part, e.message ?: "The download failed.", deletePart = false)
        }
    }

    private fun isOutOfSpace(e: IOException) = e.message?.contains("ENOSPC") == true || e.message?.contains("No space") == true

    private fun transfer(p: Params, part: File) {
        part.parentFile?.mkdirs()
        var have = fileLength(part)
        if (have > p.sizeBytes) {
            part.delete()
            have = 0
        }
        if (have == p.sizeBytes) return
        val conn = URL(p.url).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 20_000
            conn.readTimeout = 30_000
            conn.instanceFollowRedirects = true
            if (have > 0) conn.setRequestProperty("Range", "bytes=$have-")
            val code = conn.responseCode
            when {
                code == 416 -> return
                code == 200 && have > 0 -> have = 0 // server ignored Range
                code == 200 || code == 206 -> {}
                code == 408 || code == 429 || code >= 500 -> throw IOException("HTTP $code")
                else -> throw Fatal("Download failed (HTTP $code).")
            }
            RandomAccessFile(part, "rw").use { out ->
                out.seek(have)
                if (code == 200) out.setLength(0)
                val buf = ByteArray(64 * 1024)
                var lastReport = 0L
                conn.inputStream.use { input ->
                    while (!stopRequested) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        have += n
                        val now = System.currentTimeMillis()
                        if (now - lastReport >= 500) {
                            lastReport = now
                            report(p, have)
                        }
                    }
                }
            }
            if (stopRequested) return
            report(p, have)
            if (have < p.sizeBytes) throw IOException("Connection ended early")
        } finally {
            conn.disconnect()
        }
    }

    private fun report(p: Params, bytes: Long) {
        DownloadRegistry.update(p.fileName, DownloadSnapshot("running", bytes, p.sizeBytes))
        notify(progressNotification(p, bytes, p.sizeBytes))
    }

    private fun verifyAndPublish(p: Params, part: File) {
        if (fileLength(part) != p.sizeBytes) {
            fail(p, part, "The downloaded file is incomplete. Try again.", deletePart = false)
            return
        }
        DownloadRegistry.update(p.fileName, DownloadSnapshot("verifying", p.sizeBytes, p.sizeBytes))
        notify(progressNotification(p, p.sizeBytes, p.sizeBytes, indeterminate = true, text = "Verifying"))
        val digest = MessageDigest.getInstance("SHA-256")
        part.inputStream().buffered(1 shl 20).use { input ->
            val buf = ByteArray(1 shl 20)
            while (true) {
                if (stopRequested) {
                    onStopped(p)
                    return
                }
                val n = input.read(buf)
                if (n < 0) break
                digest.update(buf, 0, n)
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (!actual.equals(p.sha256, ignoreCase = true)) {
            fail(p, part, "The downloaded file failed its checksum and was removed.", deletePart = true)
            return
        }
        if (!part.renameTo(finalFile(p))) {
            fail(p, part, "Could not save the model file.", deletePart = false)
            return
        }
        DownloadRegistry.update(p.fileName, DownloadSnapshot("done", p.sizeBytes, p.sizeBytes))
        endForeground(remove = true)
        notifications.notify(RESULT_ID, resultNotification(p, "${modelName(p)} ready", "Tap to open Ramble Voice."))
        stopSelf()
    }

    private fun fail(p: Params, part: File, message: String, deletePart: Boolean) {
        if (deletePart) part.delete()
        DownloadRegistry.update(p.fileName, DownloadSnapshot("failed", fileLength(part), p.sizeBytes, message))
        endForeground(remove = true)
        notifications.notify(RESULT_ID, resultNotification(p, "${modelName(p)} download failed", message))
        stopSelf()
    }

    private fun onStopped(p: Params) {
        val part = partFile(p)
        if (cancelRequested) {
            discard(p)
            endForeground(remove = true)
        } else {
            val bytes = fileLength(part)
            DownloadRegistry.update(p.fileName, DownloadSnapshot("paused", bytes, p.sizeBytes))
            endForeground(remove = false)
            notifications.notify(NOTIFICATION_ID, pausedNotification(p, bytes))
        }
        stopSelf()
    }

    private fun discard(p: Params) {
        partFile(p).delete()
        DownloadRegistry.update(p.fileName, DownloadSnapshot("idle", 0, p.sizeBytes))
        notifications.cancel(NOTIFICATION_ID)
    }

    private fun endForeground(remove: Boolean) {
        stopForeground(if (remove) STOP_FOREGROUND_REMOVE else STOP_FOREGROUND_DETACH)
    }

    private fun sleepInterruptibly(ms: Long) {
        var left = ms
        while (left > 0 && !stopRequested) {
            Thread.sleep(minOf(left, 250))
            left -= 250
        }
    }

    // ---- notifications ----

    private fun notify(n: Notification) {
        if (!stopRequested) notifications.notify(NOTIFICATION_ID, n)
    }

    private fun modelName(p: Params) = p.title.removePrefix("Downloading ")

    private fun openAppIntent(): PendingIntent {
        val open = Intent(this, MainActivity::class.java)
            .putExtra(MainActivity.EXTRA_ROUTE, "/settings")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun action(p: Params, action: String, label: String, icon: Int, code: Int): Notification.Action {
        val pi = PendingIntent.getService(
            this,
            code,
            intentFor(this, action, p.url, p.fileName, p.sha256, p.sizeBytes, p.title),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Action.Builder(Icon.createWithResource(this, icon), label, pi).build()
    }

    private fun progressNotification(
        p: Params,
        bytes: Long,
        total: Long,
        indeterminate: Boolean = false,
        text: String? = null,
    ): Notification {
        val percent = if (total > 0) (bytes * 100 / total).toInt().coerceIn(0, 100) else 0
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_download)
            .setContentTitle(p.title)
            .setContentText(text ?: "${formatMb(bytes)} of ${formatMb(total)}")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setContentIntent(openAppIntent())
            .addAction(action(p, ACTION_PAUSE, "Pause", R.drawable.ic_action_pause, 1))
            .addAction(action(p, ACTION_CANCEL, "Cancel", R.drawable.ic_action_close, 2))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
            // Android 16: a Live Update with a segmented progress bar and the
            // percentage in the status bar chip.
            builder
                .setStyle(
                    Notification.ProgressStyle()
                        .setProgressSegments(listOf(Notification.ProgressStyle.Segment(100)))
                        .setProgress(percent)
                        .setProgressIndeterminate(indeterminate),
                )
                .setRequestPromotedOngoing(true)
            if (!indeterminate) builder.setShortCriticalText("$percent%")
        } else {
            builder.setProgress(100, percent, indeterminate)
        }
        return builder.build()
    }

    private fun pausedNotification(p: Params, bytes: Long): Notification =
        Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_download)
            .setContentTitle("${p.title} paused")
            .setContentText("${formatMb(bytes)} of ${formatMb(p.sizeBytes)}")
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(openAppIntent())
            .addAction(action(p, ACTION_START, "Resume", R.drawable.ic_action_play, 3))
            .addAction(action(p, ACTION_CANCEL, "Cancel", R.drawable.ic_action_close, 2))
            .build()

    private fun resultNotification(p: Params, title: String, text: String): Notification =
        Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_download)
            .setContentTitle(title)
            .setContentText(text)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setContentIntent(openAppIntent())
            .build()

    private fun formatMb(bytes: Long) = "%.0f MB".format(bytes / 1_000_000.0)

    // ---- files ----

    private fun modelsDir(): File = File(getExternalFilesDir(null) ?: filesDir, "models").also { it.mkdirs() }
    private fun partFile(p: Params) = File(modelsDir(), "${p.fileName}.part")
    private fun finalFile(p: Params) = File(modelsDir(), p.fileName)
    private fun fileLength(f: File) = if (f.exists()) f.length() else 0L

    private fun readParams(i: Intent): Params? {
        val url = i.getStringExtra(EXTRA_URL) ?: return null
        val fileName = i.getStringExtra(EXTRA_FILE) ?: return null
        val sha = i.getStringExtra(EXTRA_SHA) ?: return null
        val title = i.getStringExtra(EXTRA_TITLE) ?: return null
        val size = i.getLongExtra(EXTRA_SIZE, -1)
        if (size <= 0) return null
        return Params(url, fileName, sha, size, title)
    }

    companion object {
        const val CHANNEL_ID = "model_downloads"
        const val ACTION_START = "io.github.luohoa97.ramblevoice.download.START"
        const val ACTION_PAUSE = "io.github.luohoa97.ramblevoice.download.PAUSE"
        const val ACTION_CANCEL = "io.github.luohoa97.ramblevoice.download.CANCEL"
        private const val EXTRA_URL = "url"
        private const val EXTRA_FILE = "fileName"
        private const val EXTRA_SHA = "sha256"
        private const val EXTRA_SIZE = "sizeBytes"
        private const val EXTRA_TITLE = "title"
        private const val NOTIFICATION_ID = 41
        private const val RESULT_ID = 42

        fun intentFor(
            context: Context,
            action: String,
            url: String,
            fileName: String,
            sha256: String,
            sizeBytes: Long,
            title: String,
        ): Intent = Intent(context, ModelDownloadService::class.java)
            .setAction(action)
            .putExtra(EXTRA_URL, url)
            .putExtra(EXTRA_FILE, fileName)
            .putExtra(EXTRA_SHA, sha256)
            .putExtra(EXTRA_SIZE, sizeBytes)
            .putExtra(EXTRA_TITLE, title)
    }
}
