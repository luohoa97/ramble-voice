// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';

/// Android-only `ramble/system` calls used by the UI.
abstract final class SystemChannel {
  static const _channel = MethodChannel('ramble/system');

  static Future<void> openKeyboardSettings() async {
    try {
      await _channel.invokeMethod<void>('openKeyboardSettings');
    } catch (_) {}
  }

  /// The app name for an Android package, or the package name when unknown.
  static Future<String> appLabel(String packageName) async {
    try {
      return await _channel.invokeMethod<String>('appLabel', packageName) ?? packageName;
    } catch (_) {
      return packageName;
    }
  }

  static Future<bool> isKeyboardEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isKeyboardEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// Linux `ramble/window` calls.
abstract final class WindowChannel {
  static const _channel = MethodChannel('ramble/window');

  static Future<void> _call(String m) async {
    try {
      await _channel.invokeMethod<void>(m);
    } catch (_) {}
  }

  static Future<void> show() => _call('show');
  static Future<void> hide() => _call('hide');
  static Future<void> present() => _call('present');
  static Future<void> quit() => _call('quit');
}
