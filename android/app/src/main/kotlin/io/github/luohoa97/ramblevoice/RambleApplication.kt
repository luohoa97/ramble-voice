// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.app.Application
import android.content.Context
import io.github.luohoa97.ramblevoice.bubble.BubbleKeeper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Owns the [FlutterEngineGroup] that both the app Activity and the keyboard
 * service spawn their engines from, so the two share the Dart VM snapshot and
 * font/asset resources instead of paying for them twice.
 */
class RambleApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        CrashLog.install(this)
        BubbleKeeper.sync(this)
    }

    private val group: FlutterEngineGroup by lazy { FlutterEngineGroup(this) }

    /**
     * Dart entrypoints need the Flutter loader initialised first (it locates
     * the AOT bundle). FlutterEngineGroup only does that when it creates its
     * first engine, which is after we build the entrypoint, so do it here.
     */
    private fun appBundlePath(): String {
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
        }
        return loader.findAppBundlePath()
    }

    /** Engine running `main()` from lib/main.dart, for [MainActivity]. */
    fun createAppEngine(context: Context, initialRoute: String?): FlutterEngine {
        val options = FlutterEngineGroup.Options(context)
            .setDartEntrypoint(DartExecutor.DartEntrypoint(appBundlePath(), "main"))
        if (initialRoute != null) options.setInitialRoute(initialRoute)
        return group.createAndRunEngine(options).also { NpuRuntime.attach(context, it) }
    }

    /** Engine running `imeMain()` from lib/main_ime.dart, for [RambleImeService]. */
    fun createImeEngine(context: Context): FlutterEngine {
        val bundle = appBundlePath()
        val options = FlutterEngineGroup.Options(context)
            .setDartEntrypoint(
                DartExecutor.DartEntrypoint(bundle, IME_LIBRARY, IME_ENTRYPOINT),
            )
        return group.createAndRunEngine(options).also { NpuRuntime.attach(context, it) }
    }

    /** Headless engine running `bubbleMain()` from lib/main_bubble.dart, for the floating mic. */
    fun createBubbleEngine(context: Context): FlutterEngine {
        val bundle = appBundlePath()
        val options = FlutterEngineGroup.Options(context)
            .setDartEntrypoint(
                DartExecutor.DartEntrypoint(bundle, BUBBLE_LIBRARY, BUBBLE_ENTRYPOINT),
            )
        return group.createAndRunEngine(options).also { NpuRuntime.attach(context, it) }
    }

    companion object {
        const val BUBBLE_LIBRARY = "package:ramble_voice/main_bubble.dart"
        const val BUBBLE_ENTRYPOINT = "bubbleMain"
        const val IME_LIBRARY = "package:ramble_voice/main_ime.dart"
        const val IME_ENTRYPOINT = "imeMain"
    }
}
