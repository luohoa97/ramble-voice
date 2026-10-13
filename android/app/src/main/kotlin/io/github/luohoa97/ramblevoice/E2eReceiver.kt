// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import java.io.File

/**
 * End-to-end test hook for the keyboard (see `tool/e2e`). Reachable only from
 * the adb shell: the manifest protects it with android.permission.DUMP, which
 * ordinary apps cannot hold.
 *
 *   adb shell am broadcast -a io.github.luohoa97.ramblevoice.E2E \
 *       -n io.github.luohoa97.ramblevoice/.E2eReceiver --es cmd state
 *
 * The keyboard writes its JSON reply to
 * `<external files>/e2e/reply.json`.
 */
class E2eReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val cmd = intent.getStringExtra("cmd") ?: return
        val arg = intent.getStringExtra("arg")
        files = context.applicationContext.getExternalFilesDir(null)
        val f = forward
        if (f == null) {
            reply("""{"ok":false,"cmd":"$cmd","error":"The Ramble keyboard is not open"}""")
        } else {
            f(cmd, arg)
        }
    }

    companion object {
        /** Set while the keyboard engine runs. */
        @Volatile var forward: ((String, String?) -> Unit)? = null
        @Volatile private var files: File? = null

        fun reply(json: String) {
            val dir = File(files ?: return, "e2e").apply { mkdirs() }
            val tmp = File(dir, "reply.json.tmp")
            tmp.writeText(json)
            tmp.renameTo(File(dir, "reply.json"))
        }
    }
}
