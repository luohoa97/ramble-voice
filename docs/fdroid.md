# Publishing on F-Droid

Ramble Voice keeps its store listing in `fastlane/metadata/android/` (title,
descriptions, icon, phone screenshots, per-version changelogs), the layout
F-Droid and IzzyOnDroid read.

## IzzyOnDroid (F-Droid-compatible repository)

IzzyOnDroid ships the signed APK attached to each GitHub release, so it works
with the prebuilt LiteRT-LM libraries. The APK is about 65 MB, above
IzzyOnDroid's usual limit, so the request asks for a size exception (the size
is the on-device inference engine; models are downloaded separately).

Open an issue at <https://gitlab.com/IzzyOnDroid/repo/-/issues> titled
"Ramble Voice (io.github.luohoa97.ramblevoice)" with:

> Please add Ramble Voice, a GPL-3.0-or-later voice dictation app and keyboard
> for Android (speak naturally, get clean text; on-device Gemma 4 or the
> user's own Gemini key).
>
> - Source: https://github.com/luohoa97/ramble-voice
> - Releases (signed APK): https://github.com/luohoa97/ramble-voice/releases
> - Fastlane metadata: `fastlane/metadata/android/en-US`
> - Anti-features: NonFreeNet (optional Gemini cloud mode with the user's own
>   key). The optional Qualcomm NPU runtime is never bundled; on supported
>   Snapdragon phones the user can choose to download it from Maven Central.
> - The APK is about 65 MB because it contains the LiteRT-LM inference engine
>   (arm64); please consider a size exception.

## Main F-Droid repository

F-Droid builds from source and does not accept prebuilt binaries. Two parts
are prebuilt today:

1. `flutter_edge_ai_litertlm` downloads LiteRT-LM native libraries
   (`libLiteRtLm.so`, accelerators) from a GitHub release at build time.
2. `android/app/src/main/jniLibs/arm64-v8a/libLiteRtDispatch_Qualcomm.so`
   (LiteRT's Apache-2.0 Qualcomm dispatch) is committed.

Both are open source (Apache-2.0) but would have to be built from source in
the F-Droid recipe (LiteRT-LM builds with Bazel). The draft recipe is
`packaging/fdroid/io.github.luohoa97.ramblevoice.yml`; submit it as a merge
request to <https://gitlab.com/fdroid/fdroiddata> once the native libraries
build from source, or open a Request For Packaging at
<https://gitlab.com/fdroid/rfp/-/issues> to get help with that build.
