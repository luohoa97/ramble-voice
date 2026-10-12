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
