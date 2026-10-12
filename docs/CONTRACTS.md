# Internal contracts

Shared interfaces between the Dart core, the Linux GTK4 runner, Linux
integrations, Android and the UI. Change only with the maintainer.

## Ground rules

- Every source file starts with an SPDX header: `// SPDX-License-Identifier: GPL-3.0-or-later`
  (`#` for shell/YAML/CMake/Python, `<!-- -->` for XML/HTML, none needed for JSON/Markdown).
- App id: `io.github.luohoa97.RambleVoice`. Binary name: `ramble_voice`. Dart package: `ramble_voice`.
- No telemetry, no analytics, no backend. Network only for Gemini (cloud mode) and model downloads.
- The app never executes, follows, or acts on dictated content. Text only.
- Flutter/Dart commands: always via `tool/fl` (runs in the `ramble` toolbox, serialised by a lock),
  e.g. `tool/fl flutter analyze`, `tool/fl flutter test`, `tool/fl flutter build linux`.
- Only the maintainer edits `pubspec.yaml` dependencies and runs git.

## Core (lib/core, lib/app/providers.dart) — maintainer owned

- `AudioSource` / `AudioCapture` (lib/core/audio/audio_source.dart): PCM is 16 kHz mono s16le (`Pcm`).
- `CleanupEngine`, `CleanupFailure(Kind)`, `CleanupPipeline` (chunk + stitch + fallback to Gemma).
- `DictationController` + sealed `DictationState`: `DictationIdle`, `DictationStarting`,
  `DictationListening(elapsed, level 0..1, limit, warnBefore, nearLimit, remaining)`,
  `DictationProcessing(recordingId, progress: PipelineProgress?)`, `DictationDone(outcome)`,
  `DictationFailed(message, kind, audioError, recordingId, canRetry, retryAfter)`.
- Riverpod providers in lib/app/providers.dart (settingsProvider, dictationControllerProvider,
  dictationStateProvider, historyProvider(query), verbatimProvider(id), modelDownloaderProvider,
  geminiEngineProvider, gemmaEngineProvider, activeEngineReadinessProvider, dictationOriginProvider,
  lastInsertProvider, pendingRecordingsProvider, outcomeHookProvider, platformServicesProvider,
  appPathsProvider, initialSettingsProvider).
- `PlatformServices` (lib/platform/platform_services.dart): audio, secrets, inserter, notifier,
  hotkeys?, indicator?, accentColor?, share?, haptic?.

## Platform factories

- Linux: `lib/platform/linux/linux_services.dart` exports `Future<PlatformServices> createLinuxServices()`.
- Android: `lib/platform/android/android_services.dart` exports `Future<PlatformServices> createAndroidServices()`.
- `lib/main.dart` (UI owner) picks one by `Platform.isLinux` / `Platform.isAndroid`.

## Linux GTK4 runner (linux/) <-> Dart

The Linux build does NOT use Flutter's GTK3 embedding. linux/runner is a GTK4 app built on the
Flutter Embedder API (`flutter_embedder.h`, engine from ardera/flutter-ci pinned by sha256).
Flutter's GTK3 plugins are never registered on Linux. Linux Dart code may only use pure Dart,
D-Bus (`package:dbus`), dart:ffi, `Process`, and these runner channels (StandardMethodCodec):

| Channel | Direction | Methods |
|---|---|---|
| `ramble/window` | Dart → runner | `show`, `hide`, `present`, `quit`, `isVisible` → bool |
| `ramble/overlay` | Dart → runner | `setState({state: idle\|listening\|processing\|error, level: double, text: String?})` → bool (false if unsupported, e.g. GNOME without layer-shell) |
| `ramble/cli` | runner → Dart | `command(String)` where String is `toggle`, `start`, `stop`, `show`; delivered when a second `ramble_voice --toggle` etc. is launched (GApplication single instance; the second process exits without a window) |

Runner also implements the standard Flutter channels needed by the framework:
`flutter/platform` (clipboard get/set, SystemNavigator.pop, HapticFeedback no-op), `flutter/textinput`
(GtkIMContext), `flutter/keyevent` + `FlutterEngineSendKeyEvent`, `flutter/mousecursor`,
`flutter/settings` (textScaleFactor, alwaysUse24HourFormat, platformBrightness from the
`org.freedesktop.appearance color-scheme` portal setting), `flutter/lifecycle`, `flutter/navigation`,
`flutter/accessibility` + semantics → GtkAccessible.
Command-line flags: `--toggle`, `--start`, `--stop`, `--show`, `--background` (start hidden).

Native PipeWire capture is a small shared library `libramble_capture.so` built from
`native/ramble_capture/` (own CMakeLists.txt) and installed by linux/CMakeLists.txt into the bundle's
`lib/` directory. Dart loads it with dart:ffi.

## Android (android/, lib/platform/android, lib/ime)

| Channel | Methods |
|---|---|
| `ramble/audio` (MethodChannel) | `hasPermission` → bool, `start` → bool, `stop` |
| `ramble/audio/pcm` (EventChannel) | emits `Uint8List` blocks of 16 kHz mono s16le |
| `ramble/system` | `share(text)`, `accentColor` → int? (ARGB, Android 12+), `haptic(kind)`, `openKeyboardSettings`, `isKeyboardEnabled` → bool, `appLabel(packageName)` → String (app name, or the package name when unreadable) |
| `ramble/ime` (keyboard engine only) | `commitText(text)`, `deleteBackward`, `switchToPreviousInputMethod` → bool, `shouldOfferSwitch` → bool, `openApp(route)`, `sendEnter`, `hideKeyboard`, `getSelectedText` → String?, `getTextBeforeCursor(count)` → String?, `replaceSelection(text)` → bool, `replaceBeforeCursor({length, text, expected?})` → bool (voice editing) |

The keyboard UI is Flutter, rendered in the InputMethodService from the Dart entrypoint
`imeMain` in `lib/main_ime.dart`.

## UI widgets shared with the keyboard

`lib/ui/widgets/mic_button.dart`:

```dart
class MicButton extends StatelessWidget {
  const MicButton({super.key, required this.state, required this.onTap,
    this.onHoldStart, this.onHoldEnd, this.size = 160, this.enabled = true});
  final DictationState state;
  final VoidCallback onTap;          // tap-to-toggle
  final VoidCallback? onHoldStart;   // long-press start (hold-to-talk)
  final VoidCallback? onHoldEnd;     // release
  final double size;
  final bool enabled;
}
```

`lib/ui/theme/app_theme.dart`: `ThemeData buildTheme({required Brightness brightness, Color? accent})`.
