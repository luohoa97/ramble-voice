// SPDX-License-Identifier: GPL-3.0-or-later

/// End-to-end test hook for the keyboard, driven over adb by `tool/e2e`
/// (also exposed as an MCP server, `tool/e2e/ramble_e2e_mcp.py`).
///
/// Commands arrive through `E2eReceiver`, which only the adb shell can reach
/// (it requires android.permission.DUMP). They press the keyboard's own
/// buttons and report state; they never act on anything outside the keyboard.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../core/audio/injectable_audio_source.dart';
import '../core/audio/pcm.dart';
import '../core/dictation/dictation_controller.dart';
import '../platform/android/ime_bridge.dart';
import 'edit_session.dart';

class E2eHook {
  E2eHook({required this.container, required this.bridge, required this.audio});

  final ProviderContainer container;
  final ImeBridge bridge;
  final InjectableAudioSource audio;

  /// Recent dictation states, oldest first, for the test to inspect.
  final _trail = <String>[];
  String? _lastText;
  String? _lastEngine;
  double _peakLevel = 0;

  void attach() {
    bridge.onE2e = _handle;
    container.read(dictationControllerProvider).states.listen((s) {
      final name = s.runtimeType.toString();
      if (_trail.isEmpty || _trail.last != name) {
        _trail.add(name);
        if (_trail.length > 20) _trail.removeAt(0);
      }
      if (s is DictationListening && s.level > _peakLevel) _peakLevel = s.level;
      if (s is DictationDone) {
        _lastText = s.outcome.text;
        _lastEngine = '${s.outcome.engine.name}${s.outcome.fellBack ? ' (fallback: ${s.outcome.fallbackReason?.message})' : ''}';
      }
    });
  }

  Future<String> _handle(String cmd, String? arg) async {
    try {
      final out = await _run(cmd, arg);
      return jsonEncode({'ok': true, 'cmd': cmd, ...out});
    } on Object catch (e) {
      return jsonEncode({'ok': false, 'cmd': cmd, 'error': '$e'});
    }
  }

  Future<Map<String, Object?>> _run(String cmd, String? arg) async {
    final dc = container.read(dictationControllerProvider);
    final edit = container.read(imeEditProvider.notifier);
    switch (cmd) {
      case 'state':
        return await _state();
      case 'toggle':
        await dc.toggle();
      case 'start':
        _trail.clear();
        _peakLevel = 0;
        await dc.start();
      case 'stop':
        await dc.stop();
      case 'pause':
        await dc.pause();
      case 'resume':
        await dc.resume();
      case 'discard':
        await dc.discard();
      case 'edit':
        await edit.begin();
      case 'editStop':
        await edit.finish();
      case 'editUndo':
        await edit.undo();
      case 'abc':
        await bridge.switchToPreviousInputMethod();
      case 'enter':
        await bridge.sendEnter();
      case 'backspace':
        await bridge.deleteBackward();
      case 'screen':
        // What conversation context would send (the setting is not checked here).
        return {'screen': await bridge.getScreenContext(1500)};
      case 'insert':
        // The same insert path a finished dictation takes.
        final r = await container.read(platformServicesProvider).inserter.insert(arg ?? '');
        return {'method': r.method.name};
      case 'wav':
        // Plays a 16 kHz mono WAV into a normal dictation (or an edit when
        // `arg` starts with "edit:"), then stops it like the user would.
        final isEdit = arg != null && arg.startsWith('edit:');
        final path = isEdit ? arg.substring(5) : arg!;
        final pcm = WavEncoder.decode(await File(path).readAsBytes());
        _trail.clear();
        _peakLevel = 0;
        if (isEdit) {
          audio.inject(pcm, onEnd: () => unawaited(edit.finish()));
          await edit.begin();
        } else {
          audio.inject(pcm, onEnd: () => unawaited(dc.stop()));
          await dc.start();
        }
        return {'seconds': Pcm.durationOf(pcm.length).inMilliseconds / 1000};
      default:
        throw ArgumentError('unknown command $cmd');
    }
    return await _state();
  }

  Future<Map<String, Object?>> _state() async {
    final s = container.read(dictationControllerProvider).state;
    final e = container.read(imeEditProvider);
    final info = bridge.current;
    return {
      'state': s.runtimeType.toString(),
      if (s is DictationListening) ...{'level': s.level, 'elapsedMs': s.elapsed.inMilliseconds, 'paused': s.paused},
      if (s is DictationFailed) 'failure': s.message,
      if (s is DictationIdle && s.notice != null) 'notice': s.notice,
      'trail': _trail,
      'peakLevel': _peakLevel,
      'lastText': _lastText,
      'lastEngine': _lastEngine,
      'edit': e.phase.name,
      if (e.message != null) 'editMessage': e.message,
      'field': {
        'package': info.packageName,
        'multiLine': info.multiLine,
        'password': info.isPassword,
        'action': info.action?.name,
        'before': info.isPassword ? null : await bridge.getTextBeforeCursor(400),
        'after': info.isPassword ? null : await bridge.getTextAfterCursor(200),
        'selected': info.isPassword ? null : await bridge.getSelectedText(),
      },
      'insert': container.read(lastInsertProvider)?.method.name,
    };
  }
}
