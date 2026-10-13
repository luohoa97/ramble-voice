// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.content.Context
import android.os.SystemClock
import org.json.JSONObject
import java.io.File
import java.time.LocalDateTime

/**
 * Notices when the user corrects what Ramble just typed, for the on-device
 * usage log (diagnostics; never sent anywhere).
 *
 * After an insertion the field's whole text is remembered. The floating mic's
 * accessibility service then reports the field's text as it changes, whichever
 * keyboard does the typing. When the user leaves the field, starts another
 * dictation, or [WATCH_MS] passes, the final text is compared with the text
 * right after the insertion. A change that touches the inserted words is
 * logged as "fixed" (words replaced) or "added" (words inserted into or right
 * after it), with just the changed words.
 */
object CorrectionWatch {
    private const val WATCH_MS = 3 * 60 * 1000L
    private const val MAX_WORDS_CHARS = 200

    private class Watch(
        val pkg: String,
        val original: String,
        val start: Int,
        val end: Int,
        val until: Long,
        var latest: String,
    )

    @Volatile private var watch: Watch? = null

    /** The app whose field is being watched, if any. */
    val watchedPackage: String? get() = watch?.pkg

    /** Ramble typed [inserted] into [pkg]'s field, whose whole text is now [fieldText]. */
    fun start(context: Context, pkg: String?, fieldText: String?, inserted: String) {
        finish(context)
        if (pkg == null || fieldText == null || inserted.isBlank()) return
        val at = fieldText.lastIndexOf(inserted)
        if (at < 0) return
        watch = Watch(pkg, fieldText, at, at + inserted.length, SystemClock.uptimeMillis() + WATCH_MS, fieldText)
    }

    /** The accessibility service saw [pkg]'s focused field now holding [text]. */
    fun onText(context: Context, pkg: String?, text: String?) {
        val w = watch ?: return
        if (SystemClock.uptimeMillis() > w.until) {
            finish(context)
            return
        }
        if (pkg == w.pkg && text != null) w.latest = text
    }

    /** The user left the field (or another dictation starts): compare and log. */
    fun finish(context: Context) {
        val w = watch ?: return
        watch = null
        val change = diff(w.original, w.latest, w.start, w.end) ?: return
        log(context, w.pkg, change)
    }

    private data class Change(val kind: String, val wrote: String, val now: String)

    private fun diff(o: String, f: String, start: Int, end: Int): Change? {
        if (o == f) return null
        var p = 0
        while (p < o.length && p < f.length && o[p] == f[p]) p++
        var s = 0
        while (s < o.length - p && s < f.length - p && o[o.length - 1 - s] == f[f.length - 1 - s]) s++
        val oEnd = o.length - s
        val fEnd = f.length - s
        // Only changes touching what Ramble typed (or right after it).
        if (oEnd < start || p > end) return null
        // Widen to whole words so the log reads as words.
        var a = p
        while (a > 0 && !o[a - 1].isWhitespace()) a--
        var bO = oEnd
        while (bO < o.length && !o[bO].isWhitespace()) bO++
        var bF = fEnd + (bO - oEnd)
        if (bF > f.length) bF = f.length
        val wrote = o.substring(a, bO).trim()
        val now = f.substring(a.coerceAtMost(f.length), bF.coerceAtLeast(a.coerceAtMost(f.length))).trim()
        if (wrote == now) return null
        val kind = if (oEnd == p) "added" else "fixed"
        return Change(kind, wrote.take(MAX_WORDS_CHARS), now.take(MAX_WORDS_CHARS))
    }

    /** Appends to the same on-device usage log the app writes, if it is on. */
    private fun log(context: Context, pkg: String, c: Change) {
        try {
            val settings = File(context.filesDir, "settings.json")
            if (settings.isFile && JSONObject(settings.readText()).optBoolean("usageLog", true).not()) return
            val line = JSONObject()
                .put("at", LocalDateTime.now().toString())
                .put("type", "correction")
                .put("app", pkg)
                .put("kind", c.kind)
                .put("wrote", c.wrote)
                .put("now", c.now)
            File(context.filesDir, "usage.jsonl").appendText(line.toString() + "\n")
        } catch (_: Exception) {
            // Diagnostics must never break anything.
        }
    }
}
