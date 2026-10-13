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
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicInteger

/**
 * Downloads a model file in the foreground so it keeps going when the app is
 * closed, and shows progress as an Android 16 Live Update (visible on the lock
 * screen). Fetches over several connections at once with HTTP Range, each
 * filling its own byte range of the `.part` file (progress kept in a
 * [DownloadSegments] sidecar, so it resumes after the app is killed), falls
 * back to one resumable stream when the server ignores Range, retries with
 * backoff on network loss, and only renames to the final name after the
 * SHA-256 matches.
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

    /** The server answered a range request with the whole file. */
    private class RangeIgnored : Exception("The server ignored the byte range.")

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
        val existing = DownloadSegments.downloadedBytes(partFile(p))
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
                    download(p, part)
                    break
                } catch (e: Fatal) {
                    throw e
                } catch (e: IOException) {
                    if (stopRequested) break
                    if (isOutOfSpace(e)) throw Fatal("Not enough storage space.")
                    val bytes = DownloadSegments.downloadedBytes(part)
                    DownloadRegistry.update(p.fileName, DownloadSnapshot("retrying", bytes, p.sizeBytes))
                    notify(progressNotification(p, bytes, p.sizeBytes, indeterminate = true, text = "Waiting for network"))
                    sleepInterruptibly(backoff(attempt))
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

    private fun backoff(attempt: Int) = minOf(1000L shl minOf(attempt, 5), 30_000L)

    private fun open(url: String): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 20_000
            readTimeout = 30_000
            instanceFollowRedirects = true
        }

    /**
     * Fetches the file over [CONNECTIONS] parallel range requests when the
     * server supports them, otherwise over one connection with [transfer].
     */
    private fun download(p: Params, part: File) {
        part.parentFile?.mkdirs()
        val saved = loadPlan(p, part)
        if (saved != null && saved.remaining() == 0L) return
        if (saved == null && fileLength(part) == p.sizeBytes) return
        val url = probe(p)
        if (url != null) {
            try {
                parallel(p, part, saved ?: newPlan(p, part), url)
                return
            } catch (e: RangeIgnored) {
                // Fall through: the ranges on disk are not a prefix the single stream can extend.
                part.delete()
                DownloadSegments.delete(part)
            }
        } else if (saved != null) {
            part.delete()
            DownloadSegments.delete(part)
        }
        transfer(p, part)
    }

    /**
     * Asks for the first byte only. Returns the URL after redirects (Hugging
     * Face serves files from a CDN) when the server answers with a range, or
     * null when it ignores Range and the file has to come down in one stream.
     */
    private fun probe(p: Params): String? {
        val conn = open(p.url)
        try {
            conn.setRequestProperty("Range", "bytes=0-0")
            val code = conn.responseCode
            when {
                code == 206 -> {}
                code == 200 -> return null
                code == 408 || code == 429 || code >= 500 -> throw IOException("HTTP $code")
                else -> throw Fatal("Download failed (HTTP $code).")
            }
            val total = conn.getHeaderField("Content-Range")?.substringAfterLast('/')?.toLongOrNull()
            if (total != null && total != p.sizeBytes) throw Fatal("The file on the server is not the expected size.")
            return conn.url.toString()
        } finally {
            conn.disconnect()
        }
    }

    /** The saved ranges for [part], or null if there are none. Drops a sidecar that doesn't match [p]. */
    private fun loadPlan(p: Params, part: File): DownloadSegments.Plan? {
        if (!DownloadSegments.sidecarFor(part).exists()) return null
        val plan = DownloadSegments.read(part)
        if (plan != null && plan.size == p.sizeBytes && fileLength(part) == p.sizeBytes) return plan
        // Unreadable, or for another file: what is on disk can't be trusted.
        part.delete()
        DownloadSegments.delete(part)
        return null
    }

    /** Splits the rest of the file into ranges, keeping a single-connection `.part` as a finished prefix. */
    private fun newPlan(p: Params, part: File): DownloadSegments.Plan {
        var have = fileLength(part)
        if (have > p.sizeBytes) {
            part.delete()
            have = 0
        }
        val plan = DownloadSegments.plan(p.sizeBytes, have, CONNECTIONS)
        // Sidecar first: a full-size `.part` without one would read as complete.
        DownloadSegments.write(part, plan)
        RandomAccessFile(part, "rw").use { it.setLength(p.sizeBytes) }
        return plan
    }

    /** State shared by the connections of one [parallel] run. */
    private inner class ParallelRun(firstUrl: String) {
        @Volatile
        var url: String = firstUrl

        @Volatile
        var halted = false

        @Volatile
        var error: Exception? = null

        /** Connections currently backing off after a network error. */
        val waiting = AtomicInteger()

        fun stopping() = stopRequested || halted

        /** Records the first unrecoverable error and stops the other connections. */
        @Synchronized
        fun abort(e: Exception) {
            if (error == null) error = e
            halted = true
        }

        /** The CDN link is signed and expires; the first connection to notice fetches a new one. */
        @Synchronized
        fun refreshUrl(p: Params, stale: String) {
            if (url == stale) url = probe(p) ?: throw RangeIgnored()
        }
    }

    private fun parallel(p: Params, part: File, plan: DownloadSegments.Plan, url: String) {
        val run = ParallelRun(url)
        RandomAccessFile(part, "rw").use { file ->
            val channel = file.channel
            val threads = plan.segments.filter { !it.finished }.mapIndexed { i, segment ->
                Thread({ fetchLoop(p, run, channel, segment) }, "model-download-$i").also { it.start() }
            }
            try {
                var lastSaved = System.currentTimeMillis()
                while (true) {
                    val alive = threads.filter { it.isAlive }
                    if (alive.isEmpty()) break
                    alive.first().join(500)
                    if (run.stopping()) continue
                    val bytes = plan.downloaded()
                    val active = threads.count { it.isAlive }
                    if (active > 0 && run.waiting.get() >= active) {
                        DownloadRegistry.update(p.fileName, DownloadSnapshot("retrying", bytes, p.sizeBytes))
                        notify(progressNotification(p, bytes, p.sizeBytes, indeterminate = true, text = "Waiting for network"))
                    } else {
                        report(p, bytes)
                    }
                    val now = System.currentTimeMillis()
                    if (now - lastSaved >= 2000) {
                        lastSaved = now
                        DownloadSegments.write(part, plan)
                    }
                }
            } finally {
                // Normally all connections are done already; on an exception here, stop them.
                run.halted = true
                threads.forEach { it.join() }
                // Each range only counts bytes already written, so the saved plan never runs ahead of the file.
                if (!cancelRequested) {
                    try {
                        DownloadSegments.write(part, plan)
                    } catch (e: IOException) {
                        // The last periodic save stands; resume re-fetches a little more.
                    }
                }
            }
        }
        run.error?.let { throw it }
        if (stopRequested) return
        report(p, plan.downloaded())
        if (plan.remaining() > 0) throw IOException("Connection ended early")
    }

    /** One connection: fetches [segment], retrying with backoff until it is complete or the run stops. */
    private fun fetchLoop(p: Params, run: ParallelRun, channel: FileChannel, segment: DownloadSegments.Segment) {
        var attempt = 0
        while (!run.stopping() && !segment.finished) {
            val before = segment.done.get()
            try {
                fetchSegment(p, run, channel, segment)
            } catch (e: Fatal) {
                run.abort(e)
            } catch (e: RangeIgnored) {
                run.abort(e)
            } catch (e: IOException) {
                if (run.stopping()) return
                if (isOutOfSpace(e)) {
                    run.abort(Fatal("Not enough storage space."))
                    return
                }
                if (segment.done.get() > before) attempt = 0
                run.waiting.incrementAndGet()
                try {
                    sleepInterruptibly(backoff(attempt)) { run.stopping() }
                } finally {
                    run.waiting.decrementAndGet()
                }
                attempt++
            } catch (e: Exception) {
                run.abort(e)
            }
        }
    }

    private fun fetchSegment(p: Params, run: ParallelRun, channel: FileChannel, segment: DownloadSegments.Segment) {
        val url = run.url
        var at = segment.start + segment.done.get()
        val conn = open(url)
        try {
            conn.setRequestProperty("Range", "bytes=$at-${segment.end - 1}")
            val code = conn.responseCode
            when {
                code == 206 -> {}
                code == 200 -> throw RangeIgnored()
                code == 408 || code == 429 || code >= 500 -> throw IOException("HTTP $code")
                url != p.url && (code == 401 || code == 403 || code == 404 || code == 410) -> {
                    run.refreshUrl(p, url)
                    throw IOException("HTTP $code")
                }
                else -> throw Fatal("Download failed (HTTP $code).")
            }
            val range = conn.getHeaderField("Content-Range")
            if (range != null && !range.startsWith("bytes $at-")) throw RangeIgnored()
            val buf = ByteArray(64 * 1024)
            conn.inputStream.use { input ->
                while (!run.stopping()) {
                    val want = minOf(buf.size.toLong(), segment.end - at).toInt()
                    if (want <= 0) break
                    val n = input.read(buf, 0, want)
                    if (n < 0) break
                    val bytes = ByteBuffer.wrap(buf, 0, n)
                    var pos = at
                    while (bytes.hasRemaining()) pos += channel.write(bytes, pos)
                    at += n
                    segment.done.addAndGet(n.toLong())
                }
            }
            if (run.stopping()) return
            if (!segment.finished) throw IOException("Connection ended early")
        } finally {
            conn.disconnect()
        }
    }

    /** Single connection, for servers that ignore Range. Resumes a contiguous `.part` when it can. */
    private fun transfer(p: Params, part: File) {
        part.parentFile?.mkdirs()
        var have = fileLength(part)
        if (have > p.sizeBytes) {
            part.delete()
            have = 0
        }
        if (have == p.sizeBytes) return
        val conn = open(p.url)
        try {
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
        if (fileLength(part) != p.sizeBytes || DownloadSegments.downloadedBytes(part) != p.sizeBytes) {
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
        DownloadSegments.delete(part)
        DownloadRegistry.update(p.fileName, DownloadSnapshot("done", p.sizeBytes, p.sizeBytes))
        endForeground(remove = true)
        notifications.notify(RESULT_ID, resultNotification(p, "${modelName(p)} ready", "Tap to open Ramble Voice."))
        stopSelf()
    }

    private fun fail(p: Params, part: File, message: String, deletePart: Boolean) {
        if (deletePart) {
            part.delete()
            DownloadSegments.delete(part)
        }
        DownloadRegistry.update(p.fileName, DownloadSnapshot("failed", DownloadSegments.downloadedBytes(part), p.sizeBytes, message))
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
            val bytes = DownloadSegments.downloadedBytes(part)
            DownloadRegistry.update(p.fileName, DownloadSnapshot("paused", bytes, p.sizeBytes))
            endForeground(remove = false)
            notifications.notify(NOTIFICATION_ID, pausedNotification(p, bytes))
        }
        stopSelf()
    }

    private fun discard(p: Params) {
        val part = partFile(p)
        part.delete()
        DownloadSegments.delete(part)
        DownloadRegistry.update(p.fileName, DownloadSnapshot("idle", 0, p.sizeBytes))
        notifications.cancel(NOTIFICATION_ID)
    }

    private fun endForeground(remove: Boolean) {
        stopForeground(if (remove) STOP_FOREGROUND_REMOVE else STOP_FOREGROUND_DETACH)
    }

    private fun sleepInterruptibly(ms: Long, stop: () -> Boolean = { stopRequested }) {
        var left = ms
        while (left > 0 && !stop()) {
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
            // Live Update promotion and the status chip arrived in Android 16 QPR2 (36.1).
            if (Build.VERSION.SDK_INT_FULL >= Build.VERSION_CODES_FULL.BAKLAVA_1) {
                builder.setRequestPromotedOngoing(true)
                if (!indeterminate) builder.setShortCriticalText("$percent%")
            }
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

        /** Parallel range requests per download. */
        private const val CONNECTIONS = 4

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
