// SPDX-License-Identifier: GPL-3.0-or-later

/// The guided "turn on the floating mic" sequence. Each step is offered only
/// if it is still needed, and progress is re-checked whenever the app resumes
/// (every step happens in a system screen the user leaves the app for).
library;

import 'package:flutter/foundation.dart';

import 'android_audio_source.dart';
import 'android_system.dart';

enum BubbleSetupStep { microphone, keyboard, accessibility, battery, autostart }

/// What the flow needs from the system; faked in tests.
abstract interface class BubbleSetupEnv {
  Future<bool> hasMicrophone();
  Future<bool> requestMicrophone();
  Future<bool> isKeyboardEnabled();
  Future<void> openKeyboardSettings();
  Future<bool> isBubbleEnabled();
  Future<void> openBubbleSettings();
  Future<void> openAppDetails();
  Future<bool> isIgnoringBattery();
  Future<void> requestIgnoreBattery();
  Future<bool> needsAutostartStep();
  Future<void> openOemAutostart();
  Future<int> sdkInt();
}

class AndroidBubbleSetupEnv implements BubbleSetupEnv {
  AndroidBubbleSetupEnv({AndroidSystem? system, AndroidAudioSource? audio})
    : _system = system ?? AndroidSystem(),
      _audio = audio ?? AndroidAudioSource();

  final AndroidSystem _system;
  final AndroidAudioSource _audio;

  @override
  Future<bool> hasMicrophone() => _audio.hasPermission();
  @override
  Future<bool> requestMicrophone() => _audio.requestPermission();
  @override
  Future<bool> isKeyboardEnabled() => _system.isKeyboardEnabled();
  @override
  Future<void> openKeyboardSettings() => _system.openKeyboardSettings();
  @override
  Future<bool> isBubbleEnabled() => _system.isBubbleEnabled();
  @override
  Future<void> openBubbleSettings() => _system.openBubbleSettings();
  @override
  Future<void> openAppDetails() => _system.openAppDetails();
  @override
  Future<bool> isIgnoringBattery() => _system.isIgnoringBattery();
  @override
  Future<void> requestIgnoreBattery() => _system.requestIgnoreBattery();
  @override
  Future<bool> needsAutostartStep() async {
    final m = await _system.manufacturer();
    return ['honor', 'huawei', 'xiaomi', 'redmi', 'poco'].any(m.contains);
  }

  @override
  Future<void> openOemAutostart() => _system.openOemAutostart();
  @override
  Future<int> sdkInt() => _system.sdkInt();
}

class BubbleSetup extends ChangeNotifier {
  BubbleSetup(this._env);

  final BubbleSetupEnv _env;

  /// Android 13 is where sideloaded apps lose access to accessibility until allowed.
  static const restrictedSettingsSdk = 33;

  List<BubbleSetupStep> _steps = const [];
  final _done = <BubbleSetupStep>{};
  bool _started = false;
  bool _openedAccessibility = false;
  bool _openedAutostart = false;
  bool _restricted = false;

  /// The steps this run needs, fixed when [start] is called.
  List<BubbleSetupStep> get steps => _steps;

  bool get started => _started;

  /// The next step to do, null when everything needed is done.
  BubbleSetupStep? get current {
    for (final s in _steps) {
      if (!_done.contains(s)) return s;
    }
    return null;
  }

  bool get finished => _started && current == null;

  /// 1-based number of [current] among [steps], for "Step n of m".
  int get number =>
      current == null ? _steps.length : _steps.indexOf(current!) + 1;

  /// Accessibility was opened but the service stayed off: Android blocked it
  /// as a restricted setting for a sideloaded app.
  bool get restricted => _restricted;

  Future<bool> _isDone(BubbleSetupStep s) async => switch (s) {
    BubbleSetupStep.microphone => _env.hasMicrophone(),
    BubbleSetupStep.keyboard => _env.isKeyboardEnabled(),
    BubbleSetupStep.accessibility => _env.isBubbleEnabled(),
    BubbleSetupStep.battery => _env.isIgnoringBattery(),
    BubbleSetupStep.autostart => Future.value(_openedAutostart),
  };

  /// Works out which steps are needed and begins.
  Future<void> start() async {
    final needed = <BubbleSetupStep>[];
    for (final s in BubbleSetupStep.values) {
      if (s == BubbleSetupStep.autostart && !await _env.needsAutostartStep())
        continue;
      if (!await _isDone(s)) needed.add(s);
    }
    _steps = needed;
    _done.clear();
    _started = true;
    _openedAccessibility = false;
    _openedAutostart = false;
    _restricted = false;
    notifyListeners();
  }

  /// Re-checks every step; call when the app resumes.
  Future<void> refresh() async {
    if (!_started) return;
    for (final s in _steps) {
      if (await _isDone(s)) {
        _done.add(s);
      } else if (s != BubbleSetupStep.autostart) {
        _done.remove(s);
      }
    }
    if (_done.contains(BubbleSetupStep.accessibility)) {
      _restricted = false;
    } else if (_openedAccessibility &&
        await _env.sdkInt() >= restrictedSettingsSdk) {
      _restricted = true;
    }
    notifyListeners();
  }

  /// Does the current step's action (opens a prompt or a system screen).
  Future<void> act() async {
    switch (current) {
      case null:
        return;
      case BubbleSetupStep.microphone:
        await _env.requestMicrophone();
        await refresh();
      case BubbleSetupStep.keyboard:
        await _env.openKeyboardSettings();
      case BubbleSetupStep.accessibility:
        if (_restricted) {
          await _env.openAppDetails();
        } else {
          _openedAccessibility = true;
          await _env.openBubbleSettings();
        }
      case BubbleSetupStep.battery:
        await _env.requestIgnoreBattery();
      case BubbleSetupStep.autostart:
        _openedAutostart = true;
        await _env.openOemAutostart();
    }
  }

  /// Opens the accessibility details page again (after "Allow restricted settings").
  Future<void> retryAccessibility() async {
    _openedAccessibility = true;
    _restricted = false;
    notifyListeners();
    await _env.openBubbleSettings();
  }

  /// Skips a step that cannot be verified or that the user declines.
  void skip() {
    final s = current;
    if (s == null) return;
    _done.add(s);
    notifyListeners();
  }
}
