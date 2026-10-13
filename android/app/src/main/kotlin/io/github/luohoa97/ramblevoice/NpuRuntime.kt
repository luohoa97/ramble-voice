// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.zip.ZipFile

/**
 * Optional Qualcomm NPU support for on-device Gemma.
 *
 * Qualcomm's QNN runtime is proprietary, so it is never part of the APK. On a
 * phone with a Snapdragon NPU the user can choose to download it from Maven
 * Central (com.qualcomm.qti:qnn-runtime, checked against a pinned SHA-256),
 * after accepting Qualcomm's licence. The libraries the NPU path needs are
 * extracted read-only into app storage, next to LiteRT's open-source
 * Qualcomm dispatch library (Apache-2.0, shipped in the APK).
 *
 * flutter_edge_ai asks for that directory over `flutter_gemma_bundled` /
 * `prepareNpuDispatchDir`; [attach] answers it with ours.
 */
object NpuRuntime {
    const val VERSION = "2.50.0"
    private const val AAR_SHA256 = "b507656e4031d8aa6a7ab0fecf725b941096737ad7440ad7ea288f7c9cc9d743"
    private const val AAR_URL =
        "https://repo1.maven.org/maven2/com/qualcomm/qti/qnn-runtime/$VERSION/qnn-runtime-$VERSION.aar"
    const val LICENSE_URL = "https://central.sonatype.com/artifact/com.qualcomm.qti/qnn-runtime/$VERSION"
    private const val DISPATCH = "libLiteRtDispatch_Qualcomm.so"

    /** The QNN libraries the LiteRT NPU path loads (as flutter_edge_ai_litertlm bundles them). */
    private val QNN_LIBS = listOf(
        "QnnHtp", "QnnSystem",
        "QnnHtpV73Stub", "QnnHtpV73Skel",
        "QnnHtpV75Stub", "QnnHtpV75Skel",
        "QnnHtpV79Stub", "QnnHtpV79Skel",
        "QnnHtpV81Stub", "QnnHtpV81Skel",
    ).map { "lib$it.so" }

    fun dir(context: Context) = File(context.noBackupFilesDir, "npu/$VERSION")

    fun isInstalled(context: Context): Boolean {
        val d = dir(context)
        return (QNN_LIBS + DISPATCH).all { File(d, it).isFile }
    }

    /** SoC, memory and whether Qualcomm FastRPC (the NPU driver) is present. */
    fun deviceInfo(context: Context): Map<String, Any?> {
        val mem = ActivityManager.MemoryInfo()
        context.getSystemService(ActivityManager::class.java)?.getMemoryInfo(mem)
        val fastRpc = listOf("/vendor/lib64/libcdsprpc.so", "/system/vendor/lib64/libcdsprpc.so", "/system/lib64/libcdsprpc.so")
            .any { File(it).exists() }
        return mapOf(
            "soc" to Build.SOC_MODEL,
            "socManufacturer" to Build.SOC_MANUFACTURER,
            "ramBytes" to mem.totalMem,
            "fastRpc" to fastRpc,
            "npuRuntime" to isInstalled(context),
            "npuRuntimeVersion" to VERSION,
        )
    }

    /** Downloads, verifies and unpacks the runtime. Blocking; call off the main thread. */
    fun install(context: Context, onProgress: (Long, Long) -> Unit) {
        val target = dir(context)
        val staging = File(target.parentFile, "$VERSION.staging").apply { deleteRecursively(); mkdirs() }
        val aar = File(staging, "qnn.aar")
        try {
            download(aar, onProgress)
            if (sha256(aar) != AAR_SHA256) throw IllegalStateException("The Qualcomm runtime did not match its checksum.")
            ZipFile(aar).use { zip ->
                for (name in QNN_LIBS) {
                    val entry = zip.getEntry("jni/arm64-v8a/$name") ?: throw IllegalStateException("$name is missing from the runtime")
                    zip.getInputStream(entry).use { input -> File(staging, name).outputStream().use { input.copyTo(it) } }
                }
                for (name in listOf("LICENSE.pdf", "NOTICE.txt")) {
                    zip.getEntry(name)?.let { e -> zip.getInputStream(e).use { i -> File(staging, name).outputStream().use { i.copyTo(it) } } }
                }
            }
            aar.delete()
            copyDispatchFromApk(context, File(staging, DISPATCH))
            // Android 14+ refuses to load writable code files.
            staging.listFiles()?.forEach { it.setReadOnly() }
            target.deleteRecursively()
            if (!staging.renameTo(target)) throw IllegalStateException("Could not install the Qualcomm runtime.")
        } finally {
            staging.deleteRecursively()
        }
    }

    fun remove(context: Context) {
        dir(context).parentFile?.listFiles()?.forEach { f ->
            f.walkBottomUp().forEach { it.setWritable(true); it.delete() }
        }
    }

    /** The APK keeps native libraries compressed-free and unextracted: read ours from the APK. */
    private fun copyDispatchFromApk(context: Context, dest: File) {
        val info = context.applicationInfo
        val extracted = File(info.nativeLibraryDir, DISPATCH)
        if (extracted.isFile) {
            extracted.inputStream().use { i -> dest.outputStream().use { i.copyTo(it) } }
            return
        }
        for (apk in listOf(info.sourceDir) + (info.splitSourceDirs?.toList() ?: emptyList())) {
            ZipFile(apk).use { zip ->
                val entry = zip.getEntry("lib/arm64-v8a/$DISPATCH") ?: return@use
                zip.getInputStream(entry).use { i -> dest.outputStream().use { i.copyTo(it) } }
                return
            }
        }
        throw IllegalStateException("$DISPATCH is missing from this build")
    }

    private fun download(dest: File, onProgress: (Long, Long) -> Unit) {
        var url = URL(AAR_URL)
        repeat(5) {
            val conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 20_000
            conn.readTimeout = 30_000
            conn.instanceFollowRedirects = true
            try {
                if (conn.responseCode !in 200..299) throw IllegalStateException("Download failed (HTTP ${conn.responseCode})")
                val total = conn.contentLengthLong
                var got = 0L
                conn.inputStream.use { input ->
                    dest.outputStream().use { out ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            got += n
                            onProgress(got, total)
                        }
                    }
                }
                return
            } catch (e: java.io.IOException) {
                if (it == 4) throw e
                Thread.sleep(1000L * (it + 1))
            } finally {
                conn.disconnect()
            }
        }
    }

    private fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { input ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Answers flutter_edge_ai's `prepareNpuDispatchDir` with the downloaded
     * runtime. Replaces the plugin's handler on that channel: the other calls
     * on it (bundled assets, a legacy NPU path) are not used by Ramble.
     */
    fun attach(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, "flutter_gemma_bundled").setMethodCallHandler { call, result ->
            when (call.method) {
                "prepareNpuDispatchDir" ->
                    if (isInstalled(app)) {
                        result.success(dir(app).absolutePath)
                    } else {
                        result.error("NPU_LIBS_MISSING", "The Qualcomm NPU runtime is not downloaded.", null)
                    }
                else -> result.notImplemented()
            }
        }
    }
}
