// SPDX-License-Identifier: GPL-3.0-or-later

/// Dart side of the `ramble/bubble` channel, served by the Kotlin
/// `RambleBubbleService` (headless bubble engine only).
///
/// Kotlin to Dart: `toggle`, `start`, `stop`, `cancel`, `release`,
/// `context({packageName, isMultiline})`.
/// Dart to Kotlin: `ready`, `state({phase, level, message})`, `insert(text)` -> bool.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/audio/audio_source.dart';
import '../../core/dictation/dictation_controller.dart';
import '../platform_services.dart';

enum BubblePhase { idle, listening, processing, done, error }

/// What the bubble should show.
class BubbleStatus {
  const BubbleStatus(this.phase, {this.level = 0, this.message});

  final BubblePhase phase;

  /// Input level 0..1, only meaningful while listening.
  final double level;
  final String? message;

  @override
  bool operator ==(Object other) =>
      other is BubbleStatus && other.phase == phase && other.level == level && other.message == message;

  @override
  int get hashCode => Object.hash(phase, level, message);

  Map<String, Object?> toMap() => {'phase': phase.name, 'level': level, 'message': message};
}

/// Maps the dictation state machine onto what a 52 dp bubble can show.
BubbleStatus bubbleStatusFor(DictationState state) => switch (state) {
      DictationIdle(:final notice) => BubbleStatus(BubblePhase.idle, message: notice),
      DictationStarting() => const BubbleStatus(BubblePhase.processing),
      DictationListening(:final level) => BubbleStatus(BubblePhase.listening, level: level.clamp(0.0, 1.0)),
      DictationProcessing() => const BubbleStatus(BubblePhase.processing),
      DictationDone() => const BubbleStatus(BubblePhase.done),
      DictationFailed(:final message, :final audioError) => BubbleStatus(
          BubblePhase.error,
          message: audioError == AudioSourceError.permissionDenied || audioError == AudioSourceError.deviceUnavailable
              ? '$message Open Ramble Voice and try again.'
              : message,
        ),
    };

/// The field the bubble is attached to.
class BubbleFieldContext {
  const BubbleFieldContext({this.packageName, this.isMultiline = false});

  final String? packageName;
  final bool isMultiline;
}

class BubbleBridge {
  BubbleBridge({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('ramble/bubble') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;

  Future<void> Function()? onToggle;
  Future<void> Function()? onStart;
  Future<void> Function()? onStop;
  Future<void> Function()? onCancel;

  /// Memory pressure or long idle: free the on-device model.
  Future<void> Function()? onRelease;

  /// Latest focused-field info, empty before the first field.
  BubbleFieldContext field = const BubbleFieldContext();

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'toggle':
        await onToggle?.call();
        return null;
      case 'start':
        await onStart?.call();
        return null;
      case 'stop':
        await onStop?.call();
        return null;
      case 'cancel':
        await onCancel?.call();
        return null;
      case 'release':
        await onRelease?.call();
        return null;
      case 'context':
        final a = call.arguments;
        field = a is Map
            ? BubbleFieldContext(packageName: a['packageName'] as String?, isMultiline: a['isMultiline'] as bool? ?? false)
            : const BubbleFieldContext();
        return null;
    }
    throw MissingPluginException(call.method);
  }

  /// Tells Kotlin the handler is registered, so queued commands can flow.
  Future<void> ready() => _fire('ready');

  Future<void> sendState(BubbleStatus status) => _fire('state', status.toMap());

  /// Asks Kotlin to insert [text] at the cursor of the focused field.
  /// Resolves to true when it was inserted or pasted.
  Future<bool> insert(String text) async {
    try {
      return await _channel.invokeMethod<bool>('insert', text) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _fire(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException {
      // The service is going away.
    } on MissingPluginException {
      // The service is going away.
    }
  }

  void dispose() => _channel.setMethodCallHandler(null);
}

/// Forwards dictation states to the bubble, dropping duplicates and limiting
/// level updates (the controller emits one per 30 ms audio block).
class BubbleStateRelay {
  BubbleStateRelay(
    Stream<DictationState> states,
    this._bridge, {
    this.minLevelInterval = const Duration(milliseconds: 66),
    Stopwatch? clock,
  }) : _clock = clock ?? (Stopwatch()..start()) {
    _sub = states.listen(_onState);
  }

  final BubbleBridge _bridge;
  final Duration minLevelInterval;
  final Stopwatch _clock;
  late final StreamSubscription<DictationState> _sub;

  BubbleStatus? _last;
  Duration _lastSent = Duration.zero;

  void _onState(DictationState state) {
    final status = bubbleStatusFor(state);
    final last = _last;
    if (status == last) return;
    final levelOnly = last != null && last.phase == BubblePhase.listening && status.phase == BubblePhase.listening;
    if (levelOnly && _clock.elapsed - _lastSent < minLevelInterval) return;
    _last = status;
    _lastSent = _clock.elapsed;
    unawaited(_bridge.sendState(status));
  }

  Future<void> dispose() => _sub.cancel();
}

/// Inserts through the bubble service's accessibility node actions.
class BubbleTextInserter implements TextInserter {
  BubbleTextInserter(this._bridge);

  final BubbleBridge _bridge;

  @override
  Future<InsertResult> insert(String text) async {
    if (await _bridge.insert(text)) {
      return const InsertResult(InsertMethod.typed, backend: 'Accessibility');
    }
    return const InsertResult(InsertMethod.clipboardOnly, backend: 'Clipboard', message: 'Copied, paste to insert.');
  }

  @override
  Future<void> copy(String text) => Clipboard.setData(ClipboardData(text: text));

  @override
  Future<String> describe() async => 'Floating mic (accessibility)';
}
