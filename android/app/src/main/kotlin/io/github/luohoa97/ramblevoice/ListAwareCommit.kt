// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.inputmethodservice.InputMethodService
import android.os.SystemClock
import android.view.KeyEvent

/**
 * Types multi-line dictation into a multi-line field the way a person would:
 * each line break is a real Enter press, so note apps continue their own
 * bulleted, numbered and checklist formatting (rich-text lists never see a
 * plain "\n" as a new item).
 *
 * After each Enter the new line is read back:
 * - the editor added its own marker ("• ", "2. ") -> a marker the model also
 *   wrote is dropped, so it is never doubled;
 * - the editor added nothing but the previous line was a plain-text list item
 *   -> the same marker (next number) is added, so plain-text lists continue.
 *
 * Runs off the main thread: it waits briefly for each Enter to land.
 */
class ListAwareCommit(private val service: InputMethodService) {

    fun commit(text: String): Boolean {
        val lines = text.split('\n')
        if (!commitText(lines.first())) return false
        for (line in lines.drop(1)) {
            val ic = service.currentInputConnection ?: return false
            val prevLine = currentLine() ?: ""
            val beforeLen = ic.getTextBeforeCursor(MAX, 0)?.length ?: 0
            service.sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER)
            val landed = awaitNewLine(beforeLen)
            var next = line
            val added = if (landed) currentLine() ?: "" else ""
            if (added.isNotBlank()) {
                // The editor continued the list itself.
                if (MARKER.containsMatchIn(added)) next = MARKER.replace(next, "")
            } else if (next.isNotBlank()) {
                val m = MARKER.find(prevLine)
                if (m != null && !MARKER.containsMatchIn(next)) next = nextMarker(m) + next
            }
            if (next.isNotEmpty() && !commitText(next)) return false
        }
        return true
    }

    private fun commitText(t: String): Boolean =
        t.isEmpty() || service.currentInputConnection?.commitText(t, 1) == true

    /** The text from the start of the cursor's line to the cursor. */
    private fun currentLine(): String? {
        val before = service.currentInputConnection?.getTextBeforeCursor(MAX, 0)?.toString() ?: return null
        return before.substring(before.lastIndexOf('\n') + 1)
    }

    /** Waits until the text before the cursor changes after an Enter. */
    private fun awaitNewLine(beforeLen: Int): Boolean {
        val until = SystemClock.uptimeMillis() + 400
        while (SystemClock.uptimeMillis() < until) {
            val now = service.currentInputConnection?.getTextBeforeCursor(MAX, 0) ?: return false
            if (now.length != beforeLen) return true
            Thread.sleep(15)
        }
        return false
    }

    private fun nextMarker(m: MatchResult): String {
        val indent = m.groupValues[1]
        val mark = m.groupValues[2]
        val num = Regex("""^(\d+)([.)])$""").find(mark)
        val next = when {
            num != null -> "${num.groupValues[1].toInt() + 1}${num.groupValues[2]}"
            mark.contains("[") -> mark.replace(Regex("""\[[xX]\]"""), "[ ]")
            else -> mark
        }
        return "$indent$next "
    }

    companion object {
        private const val MAX = 2000
        /** A plain-text list marker at the start of a line. */
        val MARKER = Regex("""^(\s*)([-*+•◦▪‣·]|\d+[.)]|[-*] \[[ xX]\]|\[[ xX]\])\s+""")
    }
}
