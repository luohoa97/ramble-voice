# Architecture

Ramble Voice is one Flutter/Dart codebase with a shared core and thin platform
layers. The exact interfaces between layers are specified in
[CONTRACTS.md](CONTRACTS.md); this document is the overview.

## Overview

```
 +-------------------------------------------------------------+
 |                        lib/ui (Flutter UI)                  |
 |   home, history, settings, MicButton, overlay/keyboard UI   |
 +----------------------------+--------------------------------+
                              | Riverpod providers (lib/app)
 +----------------------------v--------------------------------+
 |                         lib/core                            |
 |  DictationController -> AudioCapture -> Chunker             |
 |        |                                    |               |
 |        |                         CleanupPipeline            |
 |        |                 (chunk, clean, stitch, fallback)   |
 |        |                     |                  |           |
 |        |              GeminiEngine         GemmaEngine      |
 |        |              (HTTPS, opt-in)   (LiteRT-LM, local)  |
 |   history (drift/SQLite), settings, style profile,          |
 |   model catalog + downloader (SHA-256 verified)             |
 +----------------------------+--------------------------------+
                              | PlatformServices
        +---------------------+----------------------+
        |                                            |
 +------v--------------------------+   +-------------v-----------------+
 | lib/platform/linux              |   | lib/platform/android, lib/ime |
 | D-Bus portals, hotkeys, tray,   |   | AudioRecord, IME commitText,  |
 | insertion (portal/wtype/xdotool |   | haptics, accent color         |
 | /ydotool/clipboard), libpipewire|   | (Kotlin InputMethodService)   |
 | capture over dart:ffi           |   +-------------------------------+
 +------+--------------------------+
        | channels: ramble/window, ramble/overlay, ramble/cli
 +------v--------------------------+
 | linux/runner: GTK4 app on the   |
 | Flutter Embedder API, layer-    |
 | shell overlay, single instance  |
 +---------------------------------+
```

## Module map

| Path | Role |
|---|---|
| `lib/core/audio` | `AudioSource`/`AudioCapture`, PCM type (16 kHz mono s16le), silence-aware chunker |
| `lib/core/cleanup` | `CleanupEngine` interface, `CleanupPipeline`, prompt, Gemini and Gemma engines |
| `lib/core/dictation` | `DictationController` state machine, recording vault for retry |
| `lib/core/history` | drift/SQLite history of dictations |
| `lib/core/models` | model catalog (sizes, URLs, SHA-256) and downloader |
| `lib/core/settings`, `lib/core/style` | settings and the user's writing style profile |
| `lib/app/providers.dart` | Riverpod wiring |
| `lib/platform/linux` | Linux services: portals over D-Bus, capture over FFI, insertion, tray, hotkeys |
| `lib/platform/android`, `lib/ime` | Android services and keyboard engine |
| `lib/ui` | theme, widgets, screens |
| `linux/runner` | GTK4 runner on the Flutter Embedder API |
| `native/ramble_capture` | `libramble_capture.so`, PipeWire capture (`pw_stream`) |
| `android/` | Kotlin: audio, system and IME channels |
| `packaging/` | Flatpak manifest, desktop file, metainfo, icons, host setup script |

## Data flow

1. The user presses the hotkey, taps the mic button or holds the keyboard mic.
2. `DictationController` asks the platform `AudioCapture` to start. Audio arrives
   as 16 kHz mono PCM.
3. When recording stops, the chunker splits audio at silences into pieces of at
   most about 28 seconds (Gemma 4 accepts at most 30 seconds per request).
4. `CleanupPipeline` sends each chunk, with the style prompt, to the active
   engine. The model hears the audio directly and returns clean text.
   The prompt treats everything spoken as content to clean, never as
   instructions.
5. If Gemini fails (rate limit, offline, quota), the pipeline falls back to
   on-device Gemma when it is downloaded.
6. Chunk results are stitched into one text. The text is stored in history and
   handed to the platform inserter.
7. Linux: inserter tries the RemoteDesktop portal, wtype, xdotool, ydotool, and
   finally the clipboard with a notification. Android: `commitText` on the
   keyboard's input connection.

The result is only ever text. Nothing in the pipeline interprets or executes
dictated content.

## Linux runner

Flutter's own Linux embedding is GTK3 only, so `linux/runner` is a GTK4
application that drives the engine through the Embedder API. Engine binaries are
fetched by `linux/fetch_engine.sh` from ardera/flutter-ci and pinned by SHA-256.
Flutter's GTK3 plugins are not registered, so Linux Dart code uses only pure
Dart, D-Bus (`package:dbus`), `dart:ffi`, `Process`, and the runner channels
below. The runner is a GApplication, so a second `ramble_voice --toggle`
process forwards its command to the running instance and exits.

## Platform channels

| Channel | Direction | Purpose |
|---|---|---|
| `ramble/window` | Dart to runner | show, hide, present, quit, isVisible |
| `ramble/overlay` | Dart to runner | overlay state, level and text (false if unsupported) |
| `ramble/cli` | runner to Dart | `toggle`, `start`, `stop`, `show` from the command line |
| `ramble/audio` | Dart to Android | permission, start, stop recording |
| `ramble/audio/pcm` | Android to Dart | PCM event stream |
| `ramble/system` | Dart to Android | share, accent color, haptics, keyboard settings |
| `ramble/ime` | Dart to Android | commitText, deleteBackward, switch keyboard, openApp, sendEnter, hideKeyboard |

Method details and codecs are in [CONTRACTS.md](CONTRACTS.md).

## Release pipeline

`.github/workflows/release.yml` builds the Linux bundle for x86_64 and aarch64,
wraps it into a Flatpak with `packaging/flatpak/`, builds the arm64-v8a APK with
a 16 KB page-alignment check, and attaches everything plus `SHA256SUMS` to the
GitHub release.
