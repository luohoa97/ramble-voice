// SPDX-License-Identifier: GPL-3.0-or-later

/// Starts dictation when the floating mic hands over to the keyboard.
///
/// The bubble switches the active keyboard to Ramble; the service tags the
/// resulting `inputStarted` with `autoStart` (and `hold` for hold-to-talk,
/// whose release arrives as `stopListening`).
library;

import 'dart:async';

import 'ime_bridge.dart';

class ImeAutoStart {
  ImeAutoStart({
    required ImeBridge bridge,
    required this.onStart,
    required this.onStop,
  }) {
    // `inputStarted` may have arrived while the engine was still booting.
    if (bridge.current.autoStart) _run(bridge.current.hold);
    _subs = [
      bridge.inputStarted.listen((info) {
        if (info.autoStart) _run(info.hold);
      }),
      bridge.stopRequested.listen((_) => _onRelease()),
    ];
  }

  /// Begin dictation (set the origin, start the controller).
  final Future<void> Function() onStart;

  /// Stop dictation and process it.
  final Future<void> Function() onStop;
  late final List<StreamSubscription<void>> _subs;

  bool _holding = false;
  bool _starting = false;
  bool _releasedEarly = false;

  void _run(bool hold) => unawaited(_begin(hold));

  Future<void> _begin(bool hold) async {
    _holding = hold;
    _releasedEarly = false;
    _starting = true;
    try {
      await onStart();
    } finally {
      _starting = false;
    }
    // Released while the microphone was still starting.
    if (_holding && _releasedEarly) {
      _holding = false;
      await onStop();
    }
  }

  void _onRelease() {
    if (!_holding) return;
    if (_starting) {
      _releasedEarly = true;
      return;
    }
    _holding = false;
    unawaited(onStop());
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
  }
}
