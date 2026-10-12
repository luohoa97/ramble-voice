// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.content.Context
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Local-only crash and diagnostics log in the app's external files directory
 * (Android/data/<package>/files/logs/). Nothing is uploaded. Some OEM builds
 * (e.g. HONOR MagicOS) encrypt logcat, so this is the only readable trace of
 * a keyboard or bubble crash. The file is capped at ~256 KB.
 */
object CrashLog {
    private const val MAX_BYTES = 256 * 1024
    @Volatile private var dir: File? = null

    fun install(context: Context) {
        dir = context.getExternalFilesDir("logs") ?: File(context.filesDir, "logs")
        dir?.mkdirs()
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            write("uncaught on ${thread.name}", error)
            previous?.uncaughtException(thread, error)
        }
    }

    fun note(message: String) = append("${stamp()} $message\n")

    fun write(where: String, error: Throwable) {
        val trace = StringWriter().also { error.printStackTrace(PrintWriter(it)) }.toString()
        append("${stamp()} CRASH $where\n$trace\n")
    }

    private fun stamp() = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date())

    @Synchronized
    private fun append(text: String) {
        val d = dir ?: return
        try {
            val f = File(d, "native.log")
            if (f.exists() && f.length() > MAX_BYTES) f.renameTo(File(d, "native.old.log"))
            f.appendText(text)
        } catch (_: Throwable) {
        }
    }
}
