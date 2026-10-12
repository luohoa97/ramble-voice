// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../core/dictation/dictation_controller.dart';
import '../platform/platform_services.dart';
import 'util/hotkey_state.dart';
import 'util/system_channel.dart';

/// Connects hotkeys, CLI commands, the tray/overlay indicator and the window
/// to the dictation controller. Linux only.
class LinuxIntegration {
  LinuxIntegration(this.container);

  final ProviderContainer container;
  final _subs = <StreamSubscription<dynamic>>[];
  ProviderSubscription<AsyncValue<DictationState>>? _stateSub;
  var _holdSupported = false;

  /// True while the hold-to-talk key is down. A release that arrives while
  /// the mic is still starting stops recording as soon as it is listening.
  var _held = false;

  PlatformServices get _services => container.read(platformServicesProvider);
  DictationController get _controller => container.read(dictationControllerProvider);

  void _startFromHotkey() {
    if (_controller.isBusy) return;
    container.read(dictationOriginProvider.notifier).set(DictationOrigin.hotkey);
    container.read(lastInsertProvider.notifier).set(null);
    _controller.start();
  }

  void _toggleFromHotkey() {
    if (_controller.state is DictationListening) {
      _controller.stop();
    } else {
      _startFromHotkey();
    }
  }

  Future<void> start() async {
    final hotkeys = _services.hotkeys;
    if (hotkeys != null) {
      _subs.add(hotkeys.events.listen((e) {
        if (_holdSupported) {
          if (e.phase == HotkeyPhase.pressed) {
            _held = true;
            _startFromHotkey();
          } else {
            _held = false;
            if (_controller.state is DictationListening) _controller.stop();
          }
        } else if (e.phase == HotkeyPhase.pressed) {
          _toggleFromHotkey();
        }
      }));
      _subs.add(hotkeys.cliCommands.listen((cmd) {
        switch (cmd) {
          case 'toggle':
            _toggleFromHotkey();
          case 'start':
            _startFromHotkey();
          case 'stop':
            if (_controller.state is DictationListening) _controller.stop();
          case 'show':
            WindowChannel.present();
        }
      }));
      try {
        final status = await hotkeys.bind();
        _holdSupported = status.supportsRelease;
        container.read(hotkeyStatusProvider.notifier).set(status);
      } catch (_) {
        container.read(hotkeyStatusProvider.notifier).set(const HotkeyStatus(HotkeyBackend.none));
      }
    }

    final indicator = _services.indicator;
    if (indicator != null) {
      try {
        await indicator.init(
          onToggle: _toggleFromHotkey,
          onShowWindow: WindowChannel.present,
          onQuit: WindowChannel.quit,
        );
        _stateSub = container.listen<AsyncValue<DictationState>>(
          dictationStateProvider,
          (_, next) {
            final s = next.value;
            if (s != null) _pushIndicator(indicator, s);
            if (s is DictationListening && _holdSupported && !_held &&
                container.read(dictationOriginProvider) == DictationOrigin.hotkey) {
              _controller.stop();
            }
          },
          fireImmediately: true,
        );
      } catch (_) {}
    }
  }

  void _pushIndicator(StatusIndicator indicator, DictationState s) {
    switch (s) {
      case DictationListening(:final level):
        indicator.show(IndicatorState.listening, level: level);
      case DictationStarting():
        indicator.show(IndicatorState.listening);
      case DictationProcessing():
        indicator.show(IndicatorState.processing);
      case DictationFailed(:final message):
        indicator.show(IndicatorState.error, text: message);
      case DictationIdle() || DictationDone():
        indicator.show(IndicatorState.idle);
    }
  }

  Future<void> dispose() async {
    _stateSub?.close();
    for (final s in _subs) {
      await s.cancel();
    }
  }
}
