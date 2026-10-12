// SPDX-License-Identifier: GPL-3.0-or-later

/// Dart side of the `ramble/ime` channel, served by the Kotlin
/// `RambleImeService` (keyboard engine only).
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// App routes the keyboard can deep-link into with [ImeBridge.openApp].
abstract final class ImeRoutes {
  static const home = '/';
  static const settings = '/settings';

  /// Where the user downloads or switches the on-device model.
  static const models = '/settings/models';

  /// Where microphone access is requested (the Activity engine can prompt;
  /// the keyboard cannot).
  static const permissions = '/onboarding';
}

/// What the focused text field asked of the keyboard.
class ImeInputInfo {
  const ImeInputInfo({
    this.inputType = 0,
    this.imeOptions = 0,
    this.actionId = 0,
    this.actionLabel,
    this.packageName,
    this.isPassword = false,
    this.multiLine = false,
  });

  factory ImeInputInfo.fromMap(Map<Object?, Object?> m) => ImeInputInfo(
        inputType: (m['inputType'] as num?)?.toInt() ?? 0,
        imeOptions: (m['imeOptions'] as num?)?.toInt() ?? 0,
        actionId: (m['actionId'] as num?)?.toInt() ?? 0,
        actionLabel: m['actionLabel'] as String?,
        packageName: m['packageName'] as String?,
        isPassword: m['isPassword'] as bool? ?? false,
        multiLine: m['multiLine'] as bool? ?? false,
      );

  final int inputType;
  final int imeOptions;

  /// `EditorInfo.imeOptions & IME_MASK_ACTION`.
  final int actionId;
  final String? actionLabel;
  final String? packageName;

  /// Dictating into password fields is disabled.
  final bool isPassword;
  final bool multiLine;

  /// `EditorInfo.IME_FLAG_NO_ENTER_ACTION`: the Enter key inserts a newline.
  bool get enterIsNewline => imeOptions & 0x40000000 != 0;

  /// The `EditorInfo.IME_ACTION_*` constant the Enter key performs, or null for
  /// a plain newline.
  ImeAction? get action {
    if (enterIsNewline) return null;
    return switch (actionId) {
      2 => ImeAction.go,
      3 => ImeAction.search,
      4 => ImeAction.send,
      5 => ImeAction.next,
      6 => ImeAction.done,
      7 => ImeAction.previous,
      _ => null,
    };
  }
}

enum ImeAction { go, search, send, next, done, previous }

/// Commands to, and events from, the keyboard service.
class ImeBridge {
  ImeBridge({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('ramble/ime') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final _started = StreamController<ImeInputInfo>.broadcast();
  final _finished = StreamController<void>.broadcast();

  /// Latest field info, `const ImeInputInfo()` before the first field.
  ImeInputInfo current = const ImeInputInfo();

  /// A text field took focus (or restarted).
  Stream<ImeInputInfo> get inputStarted => _started.stream;

  /// The keyboard was hidden or the field lost focus.
  Stream<void> get inputFinished => _finished.stream;

  /// Called when the service is being destroyed; free the on-device model here.
  Future<void> Function()? onRelease;

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'inputStarted':
        final args = call.arguments;
        current = args is Map ? ImeInputInfo.fromMap(args) : const ImeInputInfo();
        _started.add(current);
        return null;
      case 'inputFinished':
        _finished.add(null);
        return null;
      case 'release':
        await onRelease?.call();
        return null;
    }
    throw MissingPluginException(call.method);
  }

  Future<bool> _bool(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<bool>(method, args) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Inserts [text] at the cursor of the focused field.
  Future<bool> commitText(String text) => _bool('commitText', text);

  /// Deletes [count] characters (code points) before the cursor.
  Future<bool> deleteBackward({int count = 1}) => _bool('deleteBackward', count);

  /// Performs the field's IME action, or inserts a newline.
  Future<bool> sendEnter() => _bool('sendEnter');

  Future<bool> switchToPreviousInputMethod() => _bool('switchToPreviousInputMethod');
  Future<bool> shouldOfferSwitch() => _bool('shouldOfferSwitch');

  /// Opens the app (optionally at [route], see [ImeRoutes]) and hides the keyboard.
  Future<void> openApp([String route = ImeRoutes.home]) => _bool('openApp', route);

  Future<void> hideKeyboard() => _bool('hideKeyboard');

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _started.close();
    await _finished.close();
  }
}
