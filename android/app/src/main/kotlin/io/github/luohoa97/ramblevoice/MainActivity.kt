// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.graphics.Color
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var audio: AudioCaptureHandler? = null
    private var system: SystemHandler? = null
    private var download: DownloadHandler? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Android 16 enforces edge-to-edge; draw behind the bars on purpose so
        // Flutter's SafeArea/MediaQuery insets are the single source of truth.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        window.isNavigationBarContrastEnforced = false
        super.onCreate(savedInstanceState)
    }

    /** Spawn from the shared engine group (see [RambleApplication]). */
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        (application as RambleApplication).createAppEngine(context, intent?.getStringExtra(EXTRA_ROUTE))

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        audio = AudioCaptureHandler(applicationContext, messenger)
        system = SystemHandler(this, messenger) { window?.decorView }
        download = DownloadHandler(applicationContext, messenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        audio?.dispose()
        system?.dispose()
        download?.dispose()
        audio = null
        system = null
        download = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /** The keyboard's "open app" shortcut while the app is already running. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val route = intent.getStringExtra(EXTRA_ROUTE)
        if (!route.isNullOrEmpty()) {
            flutterEngine?.navigationChannel?.pushRouteInformation(route)
        }
    }

    companion object {
        /** Same key FlutterActivity reads for its initial route. */
        const val EXTRA_ROUTE = "route"
    }
}
