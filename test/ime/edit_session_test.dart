// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/app/providers.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/dictation/dictation_controller.dart' show EngineSet;
import 'package:ramble_voice/core/dictation/edit_controller.dart';
import 'package:ramble_voice/core/style/style_profile.dart';
import 'package:ramble_voice/ime/edit_session.dart';
import 'package:ramble_voice/ime/ime_app.dart';
import 'package:ramble_voice/platform/android/ime_bridge.dart';

import '../fakes/fake_audio_source.dart';
import '../fakes/fake_cleanup_engine.dart';
import '../fakes/pcm_fixtures.dart';

/// An Android text field behind the `ramble/ime` channel.
class _Field {
  _Field(this.text, {int? selStart, int? selEnd})
      : start = selStart ?? text.length,
        end = selEnd ?? selStart ?? text.length;

  String text;
  int start;
  int end;

  String? handle(MethodCall call) {
    switch (call.method) {
      case 'getSelectedText':
        return start == end ? null : text.substring(start, end);
      case 'getTextAfterCursor':
        return text.substring(end, (end + (call.arguments as int)).clamp(end, text.length));
      case 'getTextBeforeCursor':
        final n = call.arguments as int;
        return text.substring((end - n).clamp(0, end), end);
      case 'replaceSelection':
        if (start == end) return 'false';
        text = text.replaceRange(start, end, call.arguments as String);
        start = end = start + (call.arguments as String).length;
        return 'true';
      case 'replaceAroundCursor':
        final a = (call.arguments as Map).cast<String, Object?>();
        final before = a['before'] as String;
        final after = a['after'] as String;
        if (start != end) return 'false';
        if (before.length > end || text.substring(end - before.length, end) != before) return 'false';
        if (end + after.length > text.length || text.substring(end, end + after.length) != after) return 'false';
        text = text.replaceRange(end - before.length, end + after.length, a['text'] as String);
        start = end = end - before.length + (a['text'] as String).length;
        return 'true';
      case 'replaceBeforeCursor':
        final a = (call.arguments as Map).cast<String, Object?>();
        final len = a['length'] as int;
        final expected = a['expected'] as String?;
        if (start != end || len > end) return 'false';
        if (expected != null && text.substring(end - len, end) != expected) return 'false';
        text = text.replaceRange(end - len, end, a['text'] as String);
        start = end = end - len + (a['text'] as String).length;
        return 'true';
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Field field;
  late FakeAudioSource audio;
  late FakeCleanupEngine engine;
  late ProviderContainer container;

  const channel = MethodChannel('test/ime');

  setUp(() {
    field = _Field('Hello wrold. Second line.');
    audio = FakeAudioSource();
    engine = FakeCleanupEngine(defaultResult: 'REVISED');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      final r = field.handle(call);
      return switch (call.method) {
        'getSelectedText' || 'getTextBeforeCursor' || 'getTextAfterCursor' => r,
        _ => r == 'true',
      };
    });
    final bridge = ImeBridge(channel: channel);
    container = ProviderContainer(overrides: [
      imeBridgeProvider.overrideWithValue(bridge),
      editControllerProvider.overrideWith((ref) {
        final c = EditController(
          audio: audio,
          engines: () async => EngineSet(engine),
          style: () => const StyleProfile(),
        );
        ref.onDispose(c.dispose);
        return c;
      }),
    ]);
    addTearDown(() {
      container.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });
    // Keep the notifier alive.
    container.listen(imeEditProvider, (_, _) {});
  });

  Future<void> pump() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> speakAndFinish() async {
    audio.capture!.emit(tonePcm(const Duration(seconds: 1)));
    await pump();
    await container.read(imeEditProvider.notifier).finish();
    await pump();
  }

  ImeEditNotifier notifier() => container.read(imeEditProvider.notifier);
  ImeEditState state() => container.read(imeEditProvider);

  test('edits the selection and undo restores the original', () async {
    field
      ..start = 6
      ..end = 11; // "wrold"
    await notifier().begin();
    expect(state().phase, EditPhase.listening);
    expect(state().source, EditSource.selection);
    await speakAndFinish();

    expect(engine.requests.single.sourceText, 'wrold');
    expect(engine.requests.single.mode, CleanupMode.edit);
    expect(field.text, 'Hello REVISED. Second line.');
    expect(state().phase, EditPhase.applied);
    expect(state().undoable, isTrue);

    await notifier().undo();
    expect(field.text, 'Hello wrold. Second line.');
    expect(state().phase, EditPhase.idle);
  });

  test('prefers the last dictation when it is still before the cursor', () async {
    container.read(lastDictationProvider.notifier).set(const LastDictation(text: 'Second line.'));
    await notifier().begin();
    expect(state().source, EditSource.lastDictation);
    await speakAndFinish();
    expect(engine.requests.single.sourceText, 'Second line.');
    expect(field.text, 'Hello wrold. REVISED');

    // The revised text becomes the new "last dictation".
    expect(container.read(lastDictationProvider)!.text, 'REVISED');
    await notifier().undo();
    expect(field.text, 'Hello wrold. Second line.');
  });

  test('falls back to the text before the cursor when the last dictation is gone', () async {
    container.read(lastDictationProvider.notifier).set(const LastDictation(text: 'something else'));
    await notifier().begin();
    expect(state().source, EditSource.field);
    await speakAndFinish();
    expect(engine.requests.single.sourceText, 'Hello wrold. Second line.');
    expect(field.text, 'REVISED');
  });

  test('edits the text after the cursor too', () async {
    field = _Field('Hello wrold. Second line.', selStart: 6);
    await notifier().begin();
    expect(state().source, EditSource.field);
    await speakAndFinish();
    expect(engine.requests.single.sourceText, 'Hello wrold. Second line.');
    expect(field.text, 'REVISED');
    await notifier().undo();
    expect(field.text, 'Hello wrold. Second line.');
  });

  test('only edits up to 2000 characters before the cursor', () async {
    field = _Field('${'x' * 3000}END');
    await notifier().begin();
    await speakAndFinish();
    expect(engine.requests.single.sourceText!.length, editContextLimit);
    expect(field.text, '${'x' * 1003}REVISED');
  });

  test('a field that changed while speaking is left alone', () async {
    field
      ..start = 6
      ..end = 11;
    await notifier().begin();
    audio.capture!.emit(tonePcm(const Duration(seconds: 1)));
    await pump();
    field.start = field.end = 0; // the user moved the cursor
    await notifier().finish();
    await pump();
    expect(field.text, 'Hello wrold. Second line.');
    expect(state().phase, EditPhase.failed);
  });

  test('an empty field has nothing to edit and never opens the microphone', () async {
    field = _Field('');
    await notifier().begin();
    expect(state().phase, EditPhase.failed);
    expect(audio.startCount, 0);
  });

  test('password fields are refused', () async {
    final bridge = container.read(imeBridgeProvider);
    bridge.current = const ImeInputInfo(isPassword: true);
    await notifier().begin();
    expect(state().phase, EditPhase.failed);
    expect(audio.startCount, 0);
    expect(engine.requests, isEmpty);
  });

  test('dismiss while listening cancels without calling the engine', () async {
    await notifier().begin();
    await notifier().dismiss();
    expect(state().phase, EditPhase.idle);
    expect(engine.requests, isEmpty);
  });

  test('an unchanged result writes nothing and offers no undo', () async {
    engine = FakeCleanupEngine(defaultResult: 'Hello wrold. Second line.');
    await notifier().begin();
    await speakAndFinish();
    expect(state().unchanged, isTrue);
    expect(state().undoable, isFalse);
    expect(field.text, 'Hello wrold. Second line.');
  });

  group('ImeBridge', () {
    test('getTextAfterCursor reads the text after the cursor', () async {
      field = _Field('Hello world', selStart: 5);
      final bridge = container.read(imeBridgeProvider);
      expect(await bridge.getTextAfterCursor(4), ' wor');
      expect(await bridge.getTextAfterCursor(100), ' world');
      expect(await bridge.getTextBeforeCursor(3), 'llo');
    });

    test('getSelectedText and getTextBeforeCursor tolerate a missing handler', () async {
      final bridge = ImeBridge(channel: const MethodChannel('test/none'));
      expect(await bridge.getSelectedText(), isNull);
      expect(await bridge.getTextBeforeCursor(5), isNull);
      expect(await bridge.getTextAfterCursor(5), isNull);
      expect(await bridge.replaceSelection('x'), isFalse);
      expect(await bridge.replaceBeforeCursor(1, 'x', expected: 'y'), isFalse);
    });
  });

}
