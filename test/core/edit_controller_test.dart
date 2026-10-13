// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/audio/audio_source.dart';
import 'package:ramble_voice/core/audio/pcm.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/cleanup/cleanup_pipeline.dart';
import 'package:ramble_voice/core/dictation/dictation_controller.dart'
    show EngineSet;
import 'package:ramble_voice/core/dictation/edit_controller.dart';
import 'package:ramble_voice/core/style/style_profile.dart';

import '../fakes/fake_audio_source.dart';
import '../fakes/fake_cleanup_engine.dart';
import '../fakes/pcm_fixtures.dart';

const _second = Duration(seconds: 1);

class _Rig {
  _Rig(this.audio, this.primary, this.fallback, this.controller);

  final FakeAudioSource audio;
  final FakeCleanupEngine primary;
  final FakeCleanupEngine? fallback;
  final EditController controller;

  static _Rig create({
    FakeAudioSource? audio,
    FakeCleanupEngine? primary,
    FakeCleanupEngine? fallback,
    bool Function()? isBlocked,
    Duration maxInstruction = const Duration(seconds: 60),
  }) {
    final a = audio ?? FakeAudioSource();
    final p = primary ?? FakeCleanupEngine(defaultResult: 'Revised.');
    final c = EditController(
      audio: a,
      engines: () async => EngineSet(p, fallback),
      style: () => const StyleProfile(),
      isBlocked: isBlocked,
      maxInstruction: maxInstruction,
    );
    addTearDown(c.dispose);
    return _Rig(a, p, fallback, c);
  }

  Future<void> speak(int seconds) async {
    for (var i = 0; i < seconds; i++) {
      audio.capture!.emit(tonePcm(_second));
    }
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

void main() {
  test(
    'happy path returns the revised text and keeps the original for undo',
    () async {
      final rig = _Rig.create();
      await rig.controller.startEdit('Original text.');
      expect(rig.controller.state, isA<EditListening>());
      expect(rig.controller.isBusy, isTrue);
      await rig.speak(2);
      await rig.controller.stop();

      final done = rig.controller.state as EditDone;
      expect(done.outcome.original, 'Original text.');
      expect(done.outcome.revised, 'Revised.');
      expect(done.outcome.changed, isTrue);
      expect(done.outcome.duration, const Duration(seconds: 2));
      expect(done.outcome.engine, EngineKind.gemini);
      expect(rig.controller.isBusy, isFalse);
    },
  );

  test(
    'the engine gets edit mode, the source text and the instruction audio',
    () async {
      final rig = _Rig.create();
      await rig.controller.startEdit('Original text.');
      await rig.speak(1);
      await rig.controller.stop();
      final req = rig.primary.requests.single;
      expect(req.mode, CleanupMode.edit);
      expect(req.sourceText, 'Original text.');
      expect(req.pcm.length, Pcm.bytesPerSecond);
    },
  );

  test('unchanged output is reported as not changed', () async {
    final rig = _Rig.create(primary: FakeCleanupEngine(defaultResult: 'Same.'));
    await rig.controller.startEdit('Same.');
    await rig.speak(1);
    await rig.controller.stop();
    expect((rig.controller.state as EditDone).outcome.changed, isFalse);
  });

  test('refuses to start while dictation is running', () async {
    final rig = _Rig.create(isBlocked: () => true);
    await rig.controller.startEdit('Text');
    expect(rig.controller.state, isA<EditIdle>());
    expect(rig.audio.startCount, 0);
  });

  test('empty or oversized source never starts the microphone', () async {
    final rig = _Rig.create();
    await rig.controller.startEdit('   ');
    expect((rig.controller.state as EditIdle).notice, isNotNull);
    await rig.controller.startEdit('x' * 12001);
    expect(rig.controller.state, isA<EditFailed>());
    expect(rig.audio.startCount, 0);
  });

  test('permission denied fails with the audio error', () async {
    final rig = _Rig.create(
      audio: FakeAudioSource(permission: false, grantsOnRequest: false),
    );
    await rig.controller.startEdit('Text');
    final f = rig.controller.state as EditFailed;
    expect(f.audioError, AudioSourceError.permissionDenied);
  });

  test('a too-short recording is dropped without calling the engine', () async {
    final rig = _Rig.create();
    await rig.controller.startEdit('Text');
    rig.audio.capture!.emit(tonePcm(const Duration(milliseconds: 100)));
    await Future<void>.delayed(Duration.zero);
    await rig.controller.stop();
    expect(rig.controller.state, isA<EditIdle>());
    expect(rig.primary.requests, isEmpty);
  });

  test('cancel drops the audio and returns to idle', () async {
    final rig = _Rig.create();
    await rig.controller.startEdit('Text');
    await rig.speak(1);
    await rig.controller.cancel();
    expect(rig.controller.state, isA<EditIdle>());
    expect(rig.primary.requests, isEmpty);
    expect(rig.audio.capture!.stopped, isTrue);
  });

  test('a failure keeps the audio so retry works', () async {
    final rig = _Rig.create(
      primary: FakeCleanupEngine(
        script: [const CleanupFailure(CleanupFailureKind.noNetwork, 'offline')],
      ),
    );
    await rig.controller.startEdit('Text');
    await rig.speak(1);
    await rig.controller.stop();
    final f = rig.controller.state as EditFailed;
    expect(f.canRetry, isTrue);
    expect(f.kind, CleanupFailureKind.noNetwork);
    await rig.controller.retry();
    expect(rig.controller.state, isA<EditDone>());
    expect(rig.primary.requests, hasLength(2));
  });

  test('a non-retryable failure cannot be retried', () async {
    final rig = _Rig.create(
      primary: FakeCleanupEngine(
        script: [
          const CleanupFailure(CleanupFailureKind.invalidApiKey, 'bad key'),
        ],
      ),
    );
    await rig.controller.startEdit('Text');
    await rig.speak(1);
    await rig.controller.stop();
    expect((rig.controller.state as EditFailed).canRetry, isFalse);
  });

  test(
    'falls back to the second engine when the cloud one is offline',
    () async {
      final fallback = FakeCleanupEngine(
        kind: EngineKind.onDevice,
        defaultResult: 'Local edit.',
      );
      final rig = _Rig.create(
        primary: FakeCleanupEngine(
          script: [
            const CleanupFailure(CleanupFailureKind.noNetwork, 'offline'),
          ],
        ),
        fallback: fallback,
      );
      await rig.controller.startEdit('Text');
      await rig.speak(1);
      await rig.controller.stop();
      final o = (rig.controller.state as EditDone).outcome;
      expect(o.revised, 'Local edit.');
      expect(o.fellBack, isTrue);
      expect(o.engine, EngineKind.onDevice);
      expect(fallback.requests.single.mode, CleanupMode.edit);
    },
  );

  test('stops by itself at the instruction limit', () async {
    final rig = _Rig.create(maxInstruction: const Duration(seconds: 2));
    await rig.controller.startEdit('Text');
    await rig.speak(2);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(rig.controller.state, isA<EditDone>());
  });

  test('reset forgets the text', () async {
    final rig = _Rig.create();
    await rig.controller.startEdit('Text');
    await rig.speak(1);
    await rig.controller.stop();
    rig.controller.reset();
    expect(rig.controller.state, isA<EditIdle>());
    expect(rig.controller.sourceText, isNull);
  });

  group('CleanupPipeline.edit', () {
    test('rejects an instruction longer than the engine accepts', () async {
      final engine = FakeCleanupEngine(
        maxAudioPerRequest: const Duration(seconds: 2),
      );
      await expectLater(
        const CleanupPipeline().edit(
          pcm: tonePcm(const Duration(seconds: 3)),
          sourceText: 'Text',
          style: const StyleProfile(),
          primary: engine,
        ),
        throwsA(
          isA<CleanupFailure>().having(
            (f) => f.kind,
            'kind',
            CleanupFailureKind.audioTooLong,
          ),
        ),
      );
      expect(engine.requests, isEmpty);
    });

    test('an empty result is an error', () async {
      await expectLater(
        const CleanupPipeline().edit(
          pcm: tonePcm(_second),
          sourceText: 'Text',
          style: const StyleProfile(),
          primary: FakeCleanupEngine(defaultResult: '  '),
        ),
        throwsA(
          isA<CleanupFailure>().having(
            (f) => f.kind,
            'kind',
            CleanupFailureKind.emptyResult,
          ),
        ),
      );
    });
  });
}
