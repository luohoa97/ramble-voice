// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice.bubble

/**
 * Pure text arithmetic for inserting dictated text into a field: no Android
 * types, so it can be unit tested on the JVM.
 */
object TextSplice {
    /** [text] is the field's new content, [cursor] a UTF-16 index just after the inserted text. */
    data class Result(val text: String, val cursor: Int)

    /**
     * Inserts [insert] into [old], replacing the selection [selStart, selEnd).
     *
     * - [isHint]: [old] is the field's placeholder, not user text; it is discarded.
     * - A negative or out-of-range selection (field reports none) appends at the end.
     * - A reversed selection (some fields report end < start) is normalised.
     * - A space is added on either side when the insertion would otherwise glue two words together.
     */
    fun splice(old: CharSequence?, selStart: Int, selEnd: Int, insert: String, isHint: Boolean): Result {
        val base = if (isHint || old == null) "" else old.toString()
        var start = selStart
        var end = selEnd
        if (start < 0 || end < 0 || start > base.length || end > base.length) {
            start = base.length
            end = base.length
        }
        if (start > end) start = end.also { end = start }

        val before = base.substring(0, start)
        val after = base.substring(end)
        val lead = if (needsSpaceBetween(before.lastOrNull(), insert.firstOrNull())) " " else ""
        val trail = if (needsSpaceBetween(insert.lastOrNull(), after.firstOrNull())) " " else ""
        val inserted = lead + insert + trail
        return Result(before + inserted + after, before.length + inserted.length)
    }

    private const val OPENERS = "([{<\"'“‘/@#¿¡"
    private const val CLOSERS = ")]}>\"'”’.,;:!?%…"

    /** True when [left] directly followed by [right] would fuse two words. */
    private fun needsSpaceBetween(left: Char?, right: Char?): Boolean {
        if (left == null || right == null) return false
        if (left.isWhitespace() || right.isWhitespace()) return false
        if (left in OPENERS || right in CLOSERS) return false
        return (left.isLetterOrDigit() || left in CLOSERS) && right.isLetterOrDigit()
    }
}
