// SPDX-License-Identifier: GPL-3.0-or-later

/// Tray icon state plus an on-screen listening/processing indicator.
///
/// The GTK4 runner draws a layer-shell overlay where the compositor supports
/// it (`ramble/overlay` returns true). Where it does not (GNOME), a single
/// notification is replaced on every state change and removed when idle, so
/// the user still sees that the microphone is live.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../platform_services.dart';
import 'portal/notifications.dart';
import 'tray.dart';

class LinuxStatusIndicator implements StatusIndicator {
  LinuxStatusIndicator({
    required this.tray,
    required this.notifications,
    this._overlay = const MethodChannel('ramble/overlay'),
  });

  static const _notificationId = 'ramble-status';

  final StatusNotifierTray tray;
  final PortalNotifier notifications;
  final MethodChannel _overlay;

  bool _overlaySupported = true;
  IndicatorState _state = IndicatorState.idle;
  DateTime _lastLevelSent = DateTime.fromMillisecondsSinceEpoch(0);

  /// Whether the tray icon is visible on this desktop.
  bool get trayAvailable => tray.supported;

  /// Whether the runner is drawing the overlay (false: notification fallback).
  bool get overlayAvailable => _overlaySupported;

  @override
  Future<void> init({
    required void Function() onToggle,
    required void Function() onShowWindow,
    required void Function() onQuit,
  }) async {
    await tray.start(
      onToggle: onToggle,
      onShowWindow: onShowWindow,
      onQuit: onQuit,
    );
  }

  @override
  Future<void> show(
    IndicatorState state, {
    double level = 0,
    String? text,
  }) async {
    final changed = state != _state;
    _state = state;
    if (changed) unawaited(tray.setState(state).catchError((_) {}));

    if (_overlaySupported || changed) {
      // Level-only updates stream at audio rate; keep them under ~30 per second.
      final now = DateTime.now();
      if (!changed &&
          now.difference(_lastLevelSent) < const Duration(milliseconds: 33))
        return;
      _lastLevelSent = now;
      try {
        _overlaySupported =
            await _overlay.invokeMethod<bool>('setState', {
              'state': state.name,
              'level': level,
              'text': text,
            }) ??
            false;
      } on MissingPluginException {
        _overlaySupported = false;
      } on PlatformException {
        _overlaySupported = false;
      }
    }

    if (!_overlaySupported && changed) await _notify(state, text);
  }

  Future<void> _notify(IndicatorState state, String? text) async {
    try {
      switch (state) {
        case IndicatorState.idle:
          await notifications.remove(_notificationId);
        case IndicatorState.listening:
          await notifications.post(
            _notificationId,
            'Listening…',
            text ?? 'Speak now. Press the shortcut again to stop.',
            persistent: true,
            icon: trayIconFor(state),
          );
        case IndicatorState.processing:
          await notifications.post(
            _notificationId,
            'Cleaning up…',
            text ?? 'Turning your speech into text.',
            persistent: true,
            icon: trayIconFor(state),
          );
        case IndicatorState.error:
          await notifications.post(
            _notificationId,
            'Ramble Voice',
            text ?? 'Something went wrong.',
            icon: trayIconFor(state),
          );
      }
    } catch (_) {
      // A missing notification service must never break dictation.
    }
  }

  @override
  Future<void> dispose() async {
    await notifications.remove(_notificationId);
    await tray.dispose();
  }
}
