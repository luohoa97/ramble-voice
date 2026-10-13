// SPDX-License-Identifier: GPL-3.0-or-later

/// Contracts between shared Dart and the platform layers. Linux
/// implementations live in lib/platform/linux (D-Bus, dart:ffi, processes);
/// Android ones in lib/platform/android (method channels to Kotlin).
library;

import 'dart:ui' show Color;

import '../core/audio/audio_source.dart';
import '../core/settings/app_settings.dart';

/// How cleaned text reached the user.
enum InsertMethod {
  /// Typed into the focused app (RemoteDesktop portal, wtype, xdotool,
  /// ydotool, or InputConnection.commitText on Android).
  typed,

  /// Placed on the clipboard and pasted with a simulated Ctrl+V.
  pasted,

  /// Only copied to the clipboard; the user must paste.
  clipboardOnly,

  /// Nothing to insert into (e.g. dictating inside the app itself).
  none,
}

class InsertResult {
  const InsertResult(this.method, {this.backend, this.message});
  final InsertMethod method;

  /// e.g. "RemoteDesktop portal", "wtype", "xdotool", "ydotool".
  final String? backend;

  /// User-facing note when falling back (shown as a notification on Linux).
  final String? message;

  bool get delivered =>
      method == InsertMethod.typed || method == InsertMethod.pasted;
}

/// Puts text where the user was typing. Must never act on the content.
abstract interface class TextInserter {
  Future<InsertResult> insert(String text);

  /// Copies to the clipboard only.
  Future<void> copy(String text);

  /// Short diagnostic of what will be used ("RemoteDesktop portal (GNOME)").
  Future<String> describe();
}

enum HotkeyPhase { pressed, released }

class HotkeyEvent {
  const HotkeyEvent(this.phase);
  final HotkeyPhase phase;
}

enum HotkeyBackend { portal, compositorBinding, x11, evdev, none }

class HotkeyStatus {
  const HotkeyStatus(
    this.backend, {
    this.trigger,
    this.supportsRelease = false,
    this.message,
  });
  final HotkeyBackend backend;

  /// Human-readable binding, e.g. "Ctrl+Alt+Space".
  final String? trigger;

  /// Whether hold-to-talk works (press and release events).
  final bool supportsRelease;

  /// Setup instructions when the user must bind a key themselves (Sway).
  final String? message;
}

/// Global push-to-talk / toggle shortcut (Linux).
abstract interface class HotkeyService {
  Stream<HotkeyEvent> get events;

  /// Also receives `ramble-voice --toggle|--start|--stop` from other
  /// processes (compositor key bindings).
  Stream<String> get cliCommands;

  Future<HotkeyStatus> bind({String preferredTrigger = 'CTRL+ALT+space'});

  /// Opens the desktop's shortcut editor where supported (portal v2).
  Future<bool> configure();
  Future<void> dispose();
}

enum IndicatorState { idle, listening, processing, error }

/// Tray icon + listening/processing overlay or notification (Linux).
abstract interface class StatusIndicator {
  Future<void> init({
    required void Function() onToggle,
    required void Function() onShowWindow,
    required void Function() onQuit,
  });
  Future<void> show(IndicatorState state, {double level = 0, String? text});
  Future<void> dispose();
}

abstract interface class SystemNotifier {
  Future<void> notify(String title, String body);
}

/// Desktop/system integration bundle provided per platform.
class PlatformServices {
  const PlatformServices({
    required this.audio,
    required this.secrets,
    required this.inserter,
    required this.notifier,
    this.hotkeys,
    this.indicator,
    this.accentColor,
    this.share,
    this.haptic,
  });

  final AudioSource audio;
  final SecretStore secrets;
  final TextInserter inserter;
  final SystemNotifier notifier;
  final HotkeyService? hotkeys;
  final StatusIndicator? indicator;

  /// System accent (Android 12+ wallpaper colour, Linux desktop accent).
  final Future<Color?> Function()? accentColor;

  /// Android share sheet.
  final Future<void> Function(String text)? share;

  /// Haptic tick types: 'start', 'stop', 'done', 'error'.
  final Future<void> Function(String kind)? haptic;
}
