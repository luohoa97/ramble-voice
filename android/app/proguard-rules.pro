# SPDX-License-Identifier: GPL-3.0-or-later
#
# R8 rules for release builds. The Flutter Gradle plugin already adds the
# Flutter embedding keep rules, and flutter_edge_ai / flutter_secure_storage /
# permission_handler ship consumer rules. The rules here cover what is left.

# Flutter embedding: looked up by name from the engine and the manifest.
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# Our classes are referenced from AndroidManifest.xml (kept automatically) and
# from reflection-free code only, but keep channel handlers so stack traces in
# bug reports stay readable.
-keepnames class io.github.luohoa97.ramblevoice.**

# LiteRT-LM / LiteRT run through dart:ffi; native code calls back into JNI
# helpers by name where the runtime ships any.
-keep class com.google.ai.edge.** { *; }
-keep class com.google.mediapipe.** { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}

# Protobuf-lite generated messages are accessed reflectively by field name.
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite {
    <fields>;
}
-dontwarn com.google.protobuf.**

# Optional dependencies that are referenced but never present.
-dontwarn org.bouncycastle.jsse.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
-dontwarn kotlinx.coroutines.**
-dontwarn javax.annotation.**
-dontwarn com.google.errorprone.annotations.**

# Play Core is not used (no deferred components) but the Flutter embedding
# references it; silence the missing classes.
-dontwarn com.google.android.play.core.**
