// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice.bubble

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Toast
import io.github.luohoa97.ramblevoice.R

/**
 * Puts dictated text into a focused field through accessibility node actions.
 * Only the focused node's own text is read, and only to splice the insertion
 * into it; nothing is stored.
 *
 * 1. ACTION_SET_TEXT with the spliced text, then ACTION_SET_SELECTION after it.
 * 2. For WebViews and apps that ignore SET_TEXT: ACTION_PASTE via the clipboard,
 *    restoring the previous clip afterwards.
 * 3. If paste is refused too, leave the text on the clipboard and say so.
 */
class BubbleInserter(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val clipboard = context.getSystemService(ClipboardManager::class.java)

    /** Calls [done] on the main thread with true if the text reached the field. */
    fun insert(node: AccessibilityNodeInfo, text: String, done: (Boolean) -> Unit) {
        node.refresh()
        if (supports(node, AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_TEXT.id) && setText(node, text, done)) return
        paste(node, text, done)
    }

    private fun supports(node: AccessibilityNodeInfo, actionId: Int) = node.actionList.any { it.id == actionId }

    /** Returns false if the action was refused outright (the caller falls back to paste). */
    private fun setText(node: AccessibilityNodeInfo, text: String, done: (Boolean) -> Unit): Boolean {
        val spliced = TextSplice.splice(
            old = node.text,
            selStart = node.textSelectionStart,
            selEnd = node.textSelectionEnd,
            insert = text,
            isHint = node.isShowingHintText,
        )
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, spliced.text)
        }
        if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) return false

        main.postDelayed({
            node.refresh()
            val now = node.text?.toString().orEmpty()
            if (node.isShowingHintText || !now.contains(text.trim())) {
                // The app swallowed the action (common in WebViews); try the paste route.
                paste(node, text, done)
                return@postDelayed
            }
            val selection = Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, spliced.cursor.coerceAtMost(now.length))
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, spliced.cursor.coerceAtMost(now.length))
            }
            node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selection)
            done(true)
        }, VERIFY_DELAY_MS)
        return true
    }

    private fun paste(node: AccessibilityNodeInfo, text: String, done: (Boolean) -> Unit) {
        val previous = try {
            clipboard.primaryClip
        } catch (_: SecurityException) {
            null
        }
        setClip(text)
        if (!supports(node, AccessibilityNodeInfo.ACTION_PASTE) || !node.performAction(AccessibilityNodeInfo.ACTION_PASTE)) {
            // Leave the text for the user to paste themselves.
            Toast.makeText(context, R.string.bubble_copied_paste, Toast.LENGTH_SHORT).show()
            done(false)
            return
        }
        main.postDelayed({
            if (previous != null) clipboard.setPrimaryClip(previous)
            done(true)
        }, RESTORE_DELAY_MS)
    }

    /** Copies [text] flagged sensitive so the system clipboard preview does not show it. */
    fun setClip(text: String) {
        val clip = ClipData.newPlainText("Ramble Voice", text)
        clip.description.extras = PersistableBundle().apply {
            putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
        }
        clipboard.setPrimaryClip(clip)
    }

    companion object {
        private const val VERIFY_DELAY_MS = 150L
        private const val RESTORE_DELAY_MS = 500L
    }
}
