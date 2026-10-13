// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.inputmethodservice.InputMethodService
import android.os.SystemClock
import android.view.KeyEvent

/**
 * Types multi-line dictation into a multi-line field the way a person would:
 * each line break is a real Enter press, so rich-text note apps continue their
 * own bulleted, numbered and checklist formatting (a plain "\n" never makes a
 * new rich list item).
 *
 * The model's text is authoritative. After each Enter, whatever the editor
 * typed by itself on the new line (Obsidian's or Markor's "- " / "4. "
 * continuation, auto-indent) is deleted and the model's line is typed
 * exactly, so Markdown output is never doubled or bent into a list. Rich
 * editors whose bullets are formatting, not characters, add nothing visible
 * and keep their bullet.
 *
 * Runs off the main thread: it waits for each Enter to land, which web-based
 * editors (Obsidian, browsers) do late.
 */
class ListAwareCommit(private val service: InputMethodService) {

    fun commit(text: String): Boolean {
        val lines = text.split('\n')
        if (!commitText(lines.first())) return false
        for (line in lines.drop(1)) {
            val ic = service.currentInputConnection ?: return false
            val tail = ic.getTextBeforeCursor(TAIL, 0)?.toString() ?: ""
            service.sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER)
            val added = awaitNewLine(tail)
            if (added == null) {
                CrashLog.note("ime: Enter did not land in time; typing the line anyway")
            } else if (added.isNotEmpty()) {
                // The editor's own continuation: replaced by the model's line.
                service.currentInputConnection?.deleteSurroundingText(added.length, 0)
            }
            if (line.isNotEmpty() && !commitText(line)) return false
        }
        return true
    }

    private fun commitText(t: String): Boolean =
        t.isEmpty() || service.currentInputConnection?.commitText(t, 1) == true

    /**
     * Waits until an Enter has landed (a line break now follows [tail], the
     * text that was before the cursor) and the editor has stopped changing
     * the new line; returns what the editor put on it, or null if nothing
     * landed in time.
     */
    private fun awaitNewLine(tail: String): String? {
        val until = SystemClock.uptimeMillis() + 1500
        var last: String? = null
        var stableSince = 0L
        while (SystemClock.uptimeMillis() < until) {
            val now = service.currentInputConnection?.getTextBeforeCursor(TAIL * 2, 0)?.toString() ?: return null
            val nl = now.lastIndexOf('\n')
            val prefix = if (nl >= 0) now.substring(0, nl) else ""
            // Exact, or with trailing spaces the editor tidied away on Enter.
            val landed = nl >= 0 && (
                prefix.endsWith(tail) ||
                    (tail.isNotBlank() && tail.endsWith(' ') && prefix.endsWith(tail.trimEnd(' ')))
                )
            if (landed) {
                val line = now.substring(nl + 1)
                if (line == last) {
                    if (SystemClock.uptimeMillis() - stableSince >= 60) return line
                } else {
                    last = line
                    stableSince = SystemClock.uptimeMillis()
                }
            }
            Thread.sleep(15)
        }
        return last
    }

    companion object {
        /** How much text before the cursor is compared to see an Enter land. */
        private const val TAIL = 200
        /** A plain-text list marker at the start of a line. */
        val MARKER = Regex("""^(\s*)([-*+•◦▪‣·]|\d+[.)]|[-*] \[[ xX]\]|\[[ xX]\])\s+""")
    }
}
