// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/services.dart';

import '../platform_services.dart';

/// `ramble/system`: share sheet, accent colour, haptics and keyboard settings.
class AndroidSystem {
  AndroidSystem({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('ramble/system');

  final MethodChannel _channel;

  Future<void> share(String text) => _channel.invokeMethod<void>('share', text);

  /// System accent (Android 12+), null when unavailable.
  Future<Color?> accentColor() async {
    try {
      final v = await _channel.invokeMethod<int>('accentColor');
      return v == null ? null : Color(v & 0xFFFFFFFF);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// [kind] is one of 'start', 'stop', 'done', 'error'.
  Future<void> haptic(String kind) async {
    try {
      await _channel.invokeMethod<void>('haptic', kind);
    } on PlatformException {
      // Haptics are best effort.
    } on MissingPluginException {
      // Haptics are best effort.
    }
  }

  Future<void> openKeyboardSettings() => _channel.invokeMethod<void>('openKeyboardSettings');

  Future<bool> isKeyboardEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isKeyboardEnabled') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// An installed app the user can launch, for the bubble's blocklist editor.
class LaunchableApp {
  const LaunchableApp(this.packageName, this.label);
  final String packageName;
  final String label;
}

/// `ramble/system` methods for the floating mic bubble.
extension BubbleSystem on AndroidSystem {
  /// Whether the accessibility service behind the bubble is switched on.
  Future<bool> isBubbleEnabled() => _bool('isBubbleEnabled');

  /// Opens the accessibility settings entry for the bubble service.
  Future<void> openBubbleSettings() => _call('openBubbleSettings');

  /// Opens this app's system details page (where "Allow restricted settings" lives).
  Future<void> openAppDetails() => _call('openAppDetails');

  /// Mirrors the bubble preferences to the native service, which cannot read settings.json.
  Future<void> setBubbleConfig({required List<String> blockedApps, required String size}) =>
      _call('setBubbleConfig', {'blockedApps': blockedApps, 'size': size});

  /// Whether the OS exempts this app from battery optimisation.
  Future<bool> isIgnoringBattery() => _bool('isIgnoringBattery');

  /// Shows the system prompt asking to exempt this app from battery optimisation.
  Future<void> requestIgnoreBattery() => _call('requestIgnoreBattery');

  /// `Build.MANUFACTURER`, lower case; empty when unknown.
  Future<String> manufacturer() async {
    try {
      return (await _channel.invokeMethod<String>('manufacturer') ?? '').toLowerCase();
    } on PlatformException {
      return '';
    } on MissingPluginException {
      return '';
    }
  }

  /// Opens the vendor's app launch manager (Honor, Huawei), else the app details page.
  Future<void> openOemAutostart() => _call('openOemAutostart');

  /// The user turned the floating mic off from this app: stop watching for it going off.
  Future<void> forgetBubble() => _call('forgetBubble');

  Future<List<LaunchableApp>> launchableApps() async {
    try {
      final raw = await _channel.invokeListMethod<Map<Object?, Object?>>('launchableApps') ?? const [];
      return [
        for (final m in raw)
          if (m['package'] is String) LaunchableApp(m['package']! as String, m['label'] as String? ?? m['package']! as String),
      ];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  Future<bool> _bool(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _call(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException {
      // Settings screens are best effort.
    } on MissingPluginException {
      // Settings screens are best effort.
    }
  }
}

/// A message the app could not show as a system notification. There is no
/// notification permission on Android here, so the UI listens to [messages]
/// and shows them in-app (snack bar).
class AndroidNotice {
  const AndroidNotice(this.title, this.body);
  final String title;
  final String body;
}

class AndroidNotifier implements SystemNotifier {
  final _controller = StreamController<AndroidNotice>.broadcast();

  /// The most recent notice, if any.
  AndroidNotice? last;

  Stream<AndroidNotice> get messages => _controller.stream;

  @override
  Future<void> notify(String title, String body) async {
    last = AndroidNotice(title, body);
    if (!_controller.isClosed) _controller.add(last!);
  }

  Future<void> dispose() => _controller.close();
}
