// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong

/**
 * Progress of a multi-connection download. The `.part` file is allocated at
 * full size and each connection fills one byte range of it, so its length says
 * nothing about progress; `<name>.part.segments` records how much of every
 * range is on disk, so a resume after the process is killed picks each range
 * up where it stopped. Without that sidecar the `.part` file is a contiguous
 * prefix (the single-connection layout) and its length is the progress.
 */
object DownloadSegments {

    /** Bytes [start, end) of the file; the first [done] of them are on disk. */
    class Segment(val start: Long, val end: Long, done: Long) {
        val done = AtomicLong(done)
        val length get() = end - start
        val finished get() = done.get() >= length
    }

    class Plan(val size: Long, val segments: List<Segment>) {
        fun downloaded(): Long = segments.sumOf { it.done.get() }
        fun remaining(): Long = size - downloaded()
    }

    /** Ranges smaller than this are not worth their own connection. */
    private const val MIN_SEGMENT = 16L * 1024 * 1024

    fun sidecarFor(part: File) = File("${part.path}.segments")
    private fun tempFor(part: File) = File("${part.path}.segments.tmp")

    /** Splits what is left after the first [have] bytes into up to [connections] ranges. */
    fun plan(size: Long, have: Long, connections: Int): Plan {
        val segments = mutableListOf<Segment>()
        if (have > 0) segments += Segment(0, have, have)
        val rest = size - have
        if (rest > 0) {
            val count = (rest / MIN_SEGMENT).coerceIn(1L, connections.toLong()).toInt()
            val step = rest / count
            var start = have
            for (i in 0 until count) {
                val end = if (i == count - 1) size else start + step
                segments += Segment(start, end, 0)
                start = end
            }
        }
        return Plan(size, segments)
    }

    /** The saved plan for [part], or null when there is none or it can't be read. */
    fun read(part: File): Plan? {
        val file = sidecarFor(part)
        if (!file.exists()) return null
        return try {
            val json = JSONObject(file.readText())
            val array = json.getJSONArray("segments")
            val segments = (0 until array.length()).map { i ->
                val s = array.getJSONObject(i)
                val start = s.getLong("start")
                val end = s.getLong("end")
                Segment(start, end, s.getLong("done").coerceIn(0L, maxOf(0L, end - start)))
            }
            Plan(json.getLong("size"), segments)
        } catch (e: Exception) {
            null
        }
    }

    /** Written to a temp file and renamed, so a kill mid-write leaves the previous copy. */
    fun write(part: File, plan: Plan) {
        val array = JSONArray()
        for (s in plan.segments) {
            array.put(JSONObject().put("start", s.start).put("end", s.end).put("done", s.done.get()))
        }
        val json = JSONObject().put("size", plan.size).put("segments", array)
        val tmp = tempFor(part)
        tmp.writeText(json.toString())
        if (!tmp.renameTo(sidecarFor(part))) throw IOException("Could not save the download progress")
    }

    fun delete(part: File) {
        sidecarFor(part).delete()
        tempFor(part).delete()
    }

    /** Bytes of [part] that are actually downloaded, for progress and the paused state. */
    fun downloadedBytes(part: File): Long {
        if (!part.exists()) return 0
        if (sidecarFor(part).exists()) return read(part)?.downloaded() ?: 0
        return part.length()
    }
}
