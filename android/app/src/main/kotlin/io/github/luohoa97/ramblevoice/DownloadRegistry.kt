// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import java.util.concurrent.ConcurrentHashMap

/** What the model download looks like right now. [state] is one of idle, running, retrying, paused, verifying, done, failed. */
data class DownloadSnapshot(
    val state: String,
    val bytes: Long = 0,
    val total: Long = 0,
    val error: String? = null,
) {
    fun toMap(fileName: String): Map<String, Any?> =
        mapOf("fileName" to fileName, "state" to state, "bytes" to bytes, "total" to total, "error" to error)
}

/**
 * In-process hand-off between [ModelDownloadService] (writer) and
 * [DownloadHandler] (reader and event-channel sender). The service outlives
 * the Activity, so this is a singleton rather than something the handler owns.
 */
object DownloadRegistry {
    private val snapshots = ConcurrentHashMap<String, DownloadSnapshot>()

    @Volatile
    var listener: ((String, DownloadSnapshot) -> Unit)? = null

    fun get(fileName: String): DownloadSnapshot? = snapshots[fileName]

    fun update(fileName: String, snapshot: DownloadSnapshot) {
        snapshots[fileName] = snapshot
        listener?.invoke(fileName, snapshot)
    }
}
