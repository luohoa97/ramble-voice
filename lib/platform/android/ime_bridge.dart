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

  /// Custom instructions and vocabulary.
  static const style = '/settings/style';

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
    this.autoStart = false,
    this.hold = false,
  });

  factory ImeInputInfo.fromMap(Map<Object?, Object?> m) => ImeInputInfo(
        inputType: (m['inputType'] as num?)?.toInt() ?? 0,
        imeOptions: (m['imeOptions'] as num?)?.toInt() ?? 0,
        actionId: (m['actionId'] as num?)?.toInt() ?? 0,
        actionLabel: m['actionLabel'] as String?,
        packageName: m['packageName'] as String?,
        isPassword: m['isPassword'] as bool? ?? false,
        multiLine: m['multiLine'] as bool? ?? false,
        autoStart: m['autoStart'] as bool? ?? false,
        hold: m['hold'] as bool? ?? false,
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

  /// The floating mic switched to this keyboard to dictate: start listening now.
  final bool autoStart;

  /// With [autoStart]: the bubble is held (hold-to-talk) and will send
  /// [ImeBridge.stopRequested] on release.
  final bool hold;

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
  final _stop = StreamController<void>.broadcast();

  /// Latest field info, `const ImeInputInfo()` before the first field.
  ImeInputInfo current = const ImeInputInfo();

  /// A text field took focus (or restarted).
  Stream<ImeInputInfo> get inputStarted => _started.stream;

  /// The keyboard was hidden or the field lost focus.
  Stream<void> get inputFinished => _finished.stream;

  /// The floating mic's hold-to-talk was released: stop listening.
  Stream<void> get stopRequested => _stop.stream;

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
      case 'stopListening':
        _stop.add(null);
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

  Future<String?> _string(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<String>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Inserts [text] at the cursor of the focused field.
  Future<bool> commitText(String text) => _bool('commitText', text);

  /// Deletes [count] characters (code points) before the cursor.
  Future<bool> deleteBackward({int count = 1}) => _bool('deleteBackward', count);

  /// The selected text of the focused field, or null when nothing is selected
  /// (or the field does not expose it).
  Future<String?> getSelectedText() => _string('getSelectedText');

  /// Up to [count] UTF-16 units of text before the cursor, or null when the
  /// field does not expose it. Empty string means the cursor is at the start.
  Future<String?> getTextBeforeCursor(int count) => _string('getTextBeforeCursor', count);

  /// Up to [count] UTF-16 units of text after the cursor, or null when the
  /// field does not expose it.
  Future<String?> getTextAfterCursor(int count) => _string('getTextAfterCursor', count);

  /// Replaces the current selection with [text], leaving the cursor after it.
  /// False when nothing is selected.
  Future<bool> replaceSelection(String text) => _bool('replaceSelection', text);

  /// Replaces the [oldLength] UTF-16 units before the cursor with [text]. When
  /// [expected] is given, nothing is changed unless the text before the cursor
  /// still ends with exactly that (the field changed under us). False when the
  /// replacement did not happen.
  Future<bool> replaceBeforeCursor(int oldLength, String text, {String? expected}) =>
      _bool('replaceBeforeCursor', {'length': oldLength, 'text': text, 'expected': ?expected});

  /// Replaces [before] (right before the cursor) and [after] (right after it)
  /// with [text], leaving the cursor at the end of [text]. Nothing changes
  /// unless the field still holds exactly that text around the cursor.
  Future<bool> replaceAroundCursor(String before, String after, String text) =>
      _bool('replaceAroundCursor', {'before': before, 'after': after, 'text': text});

  /// Performs the field's IME action, or inserts a newline.
  Future<bool> sendEnter() => _bool('sendEnter');

  /// [auto] = the automatic hop back after a dictation: never shows a picker.
  Future<bool> switchToPreviousInputMethod({bool auto = false}) => _bool('switchToPreviousInputMethod', !auto);
  Future<bool> shouldOfferSwitch() => _bool('shouldOfferSwitch');

  /// Opens the app (optionally at [route], see [ImeRoutes]) and hides the keyboard.
  Future<void> openApp([String route = ImeRoutes.home]) => _bool('openApp', route);

  Future<void> hideKeyboard() => _bool('hideKeyboard');

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _started.close();
    await _finished.close();
    await _stop.close();
  }
}
