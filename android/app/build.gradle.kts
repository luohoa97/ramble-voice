// SPDX-License-Identifier: GPL-3.0-or-later
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: android/key.properties (storeFile, storePassword, keyAlias,
// keyPassword). When absent (local builds, forks) release falls back to the
// debug key so `flutter build apk` still produces an installable APK.
val keyProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "io.github.luohoa97.ramblevoice"
    // Android 16 (API 36) is the floor; take whatever newer level Flutter defaults to.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.luohoa97.ramblevoice"
        // Android 16+ only. LiteRT-LM needs >= 30 and arm64-v8a.
        minSdk = 36
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    packaging {
        jniLibs {
            // Keep .so files uncompressed and page-aligned in the APK (16 KB
            // page size devices map them straight from the APK).
            useLegacyPackaging = false
        }
    }

    signingConfigs {
        if (keyProperties.getProperty("storeFile") != null) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    lint {
        // Release lint downloads data and is slow in CI; run it separately if wanted.
        checkReleaseBuilds = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.16.0")
    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
