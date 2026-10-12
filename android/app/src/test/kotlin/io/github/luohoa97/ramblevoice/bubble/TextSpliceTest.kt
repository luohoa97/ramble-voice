// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice.bubble

import org.junit.Assert.assertEquals
import org.junit.Test

class TextSpliceTest {
    private fun splice(old: String?, s: Int, e: Int, insert: String, hint: Boolean = false) =
        TextSplice.splice(old, s, e, insert, hint)

    @Test fun insertsAtCursor() {
        val r = splice("Hello world", 5, 5, ", dear")
        assertEquals("Hello, dear world", r.text)
        assertEquals(11, r.cursor)
    }

    @Test fun replacesSelection() {
        val r = splice("Hello world", 6, 11, "there")
        assertEquals("Hello there", r.text)
        assertEquals(11, r.cursor)
    }

    @Test fun appendsWhenNoSelection() {
        val r = splice("Hello", -1, -1, "world")
        assertEquals("Hello world", r.text)
        assertEquals(11, r.cursor)
    }

    @Test fun hintIsDiscarded() {
        val r = splice("Type a message", 0, 0, "Hi there", hint = true)
        assertEquals("Hi there", r.text)
        assertEquals(8, r.cursor)
    }

    @Test fun emptyFieldNoSpaces() {
        assertEquals("Hi", splice("", 0, 0, "Hi").text)
        assertEquals("Hi", splice(null, -1, -1, "Hi").text)
    }

    @Test fun reversedSelectionIsNormalised() {
        assertEquals("Hello there", splice("Hello world", 11, 6, "there").text)
    }

    @Test fun outOfRangeSelectionAppends() {
        assertEquals("Hi there", splice("Hi", 50, 60, "there").text)
    }

    @Test fun noSpaceAfterOpenerOrBeforePunctuation() {
        assertEquals("(note)", splice("(", 1, 1, "note)").text)
        assertEquals("Hello.", splice("Hello", 5, 5, ".").text)
    }

    @Test fun spaceAfterSentenceEnd() {
        assertEquals("Done. Next", splice("Done.", 5, 5, "Next").text)
    }

    @Test fun trailingSpaceBeforeFollowingWord() {
        val r = splice("Hello world", 6, 6, "big")
        assertEquals("Hello big world", r.text)
        assertEquals(10, r.cursor)
    }

    @Test fun newlinesAreKept() {
        assertEquals("a\nb", splice("a\n", 2, 2, "b").text)
    }
}
