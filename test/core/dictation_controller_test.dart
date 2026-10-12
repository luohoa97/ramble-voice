// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/audio/audio_source.dart';
import 'package:ramble_voice/core/audio/pcm.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/cleanup/cleanup_pipeline.dart';
import 'package:ramble_voice/core/dictation/dictation_controller.dart';
import 'package:ramble_voice/core/dictation/recording_vault.dart';
import 'package:ramble_voice/core/style/style_profile.dart';

import '../fakes/fake_audio_source.dart';
import '../fakes/fake_cleanup_engine.dart';
import '../fakes/pcm_fixtures.dart';
import '../fakes/temp_dirs.dart';

const _second = Duration(seconds: 1);

class Rig {
  Rig._(this.audio, this.vault, this.dir, this.primary, this.fallback, this.controller, this.states, this.outcomes);

  final FakeAudioSource audio;
  final RecordingVault vault;
  final Directory dir;
  final FakeCleanupEngine primary;
  final FakeCleanupEngine? fallback;
  final DictationController controller;
  final List<DictationState> states;
  final List<DictationOutcome> outcomes;

  static Future<Rig> create({
    FakeAudioSource? audio,
    FakeCleanupEngine? primary,
    FakeCleanupEngine? fallback,
    Duration maxSession = const Duration(minutes: 10),
    Duration warnBefore = const Duration(seconds: 30),
    Duration minSpeech = const Duration(milliseconds: 400),
    Future<void> Function(DictationOutcome)? onOutcome,
  }) async {
    final dir = Directory('${(await makeTempDir()).path}/vault');
    final vault = RecordingVault(dir);
    final a = audio ?? FakeAudioSource();
    final p = primary ?? FakeCleanupEngine(defaultResult: 'Clean text.');
    final outcomes = <DictationOutcome>[];
    final controller = DictationController(
      audio: a,
      vault: vault,
      engines: () async => EngineSet(p, fallback),
      style: () => const StyleProfile(),
      onOutcome: (o) async {
        outcomes.add(o);
        await onOutcome?.call(o);
      },
      maxSession: maxSession,
      warnBefore: warnBefore,
      minSpeech: minSpeech,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
    );
    final states = <DictationState>[];
    controller.states.listen(states.add);
    addTearDown(controller.dispose);
    return Rig._(a, vault, dir, p, fallback, controller, states, outcomes);
  }

  Future<void> pump() async {
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Emits [seconds] of tone as 1 s blocks and waits for delivery.
  Future<void> speak(int seconds, {double amplitude = 0.5}) async {
    for (var i = 0; i < seconds; i++) {
      audio.capture!.emit(tonePcm(_second, amplitude: amplitude));
    }
    await pump();
  }

  Future<T> next<T extends DictationState>() =>
      controller.states.firstWhere((s) => s is T).then((s) => s as T).timeout(const Duration(seconds: 5));

  List<Type> get types => [for (final s in states) s.runtimeType];

  List<FileSystemEntity> get files => dir.existsSync() ? dir.listSync() : const [];
}

void main() {
  group('happy path', () {
    test('idle → starting → listening → processing → done', () async {
      final rig = await Rig.create();
      expect(rig.controller.state, isA<DictationIdle>());
      expect(rig.controller.isBusy, isFalse);

      await rig.controller.start();
      expect(rig.controller.state, isA<DictationListening>());
      expect(rig.controller.isBusy, isTrue);
      await rig.speak(2);
      await rig.controller.stop();

      final done = rig.controller.state as DictationDone;
      expect(done.outcome.text, 'Clean text.');
      expect(done.outcome.engine, EngineKind.gemini);
      expect(done.outcome.duration, const Duration(seconds: 2));
      expect(done.outcome.fellBack, isFalse);
      expect(done.outcome.createdAt, DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true));

      expect(rig.types.first, DictationStarting);
      expect(rig.types, contains(DictationListening));
      expect(rig.types.indexOf(DictationProcessing), greaterThan(rig.types.lastIndexOf(DictationListening)));
      expect(rig.types.last, DictationDone);
      expect(rig.controller.isBusy, isFalse);
    });

    test('onOutcome is called exactly once with the text, before done', () async {
      DictationState? stateDuringHook;
      late Rig rig;
      rig = await Rig.create(onOutcome: (o) async => stateDuringHook = rig.controller.state);
      await rig.controller.start();
      await rig.speak(1);
      await rig.controller.stop();
      expect(rig.outcomes.map((o) => o.text), ['Clean text.']);
      expect(stateDuringHook, isA<DictationProcessing>());
    });

    test('the processed recording is kept in the vault but no longer pending', () async {
      final rig = await Rig.create();
      await rig.controller.start();
      await rig.speak(1);
      await rig.controller.stop();
      final id = (rig.controller.state as DictationDone).outcome.recordingId;
      expect(await rig.vault.pending(), isEmpty);
      expect((await rig.vault.read(id))!.length, Pcm.bytesPerSecond);
    });

    test('processing reports pipeline progress', () async {
      final rig = await Rig.create();
      await rig.controller.start();
      await rig.speak(1);
      await rig.controller.stop();
      final progress = rig.states.whereType<DictationProcessing>().map((p) => p.progress).whereType<PipelineProgress>();
      expect(progress, isNotEmpty);
      expect(progress.first.chunk, 1);
      expect(progress.first.chunks, 1);
    });

    test('reset returns to idle after done but not while busy', () async {
      final rig = await Rig.create();
      await rig.controller.start();
      rig.controller.reset();
      expect(rig.controller.state, isA<DictationListening>());
      await rig.speak(1);
      await rig.controller.stop();
      rig.controller.reset();
      expect(rig.controller.state, isA<DictationIdle>());
    });
  });

  group('listening state', () {
    test('elapsed and level follow the blocks', () async {
      final rig = await Rig.create();
      await rig.controller.start();
      await rig.speak(1, amplitude: 1.0);
      var s = rig.controller.state as DictationListening;
      expect(s.elapsed, _second);
      expect(s.level, closeTo(1.0, 0.07));
      expect(s.limit, const Duration(minutes: 10));

      rig.audio.capture!.emit(silencePcm(_second));
      await rig.pump();
      s = rig.controller.state as DictationListening;
      expect(s.elapsed, const Duration(seconds: 2));
      expect(s.level, 0);
    });

    test('nearLimit turns on within warnBefore of the limit', () async {
      final rig = await Rig.create(maxSession: const Duration(seconds: 60), warnBefore: const Duration(seconds: 30));
      await rig.controller.start();
      await rig.speak(20);
      var s = rig.controller.state as DictationListening;
      expect(s.nearLimit, isFalse);
      expect(s.remaining, const Duration(seconds: 40));
      await rig.speak(10);
      s = rig.controller.state as DictationListening;
      expect(s.remaining, const Duration(seconds: 30));
      expect(s.nearLimit, isTrue);
    });

    test('auto-stops and processes at maxSession', () async {
      final rig = await Rig.create(maxSession: const Duration(seconds: 3));
      await rig.controller.start();
      final done = rig.next<DictationDone>();
      await rig.speak(3);
      final result = await done;
      expect(result.outcome.duration, const Duration(seconds: 3));
      expect(rig.audio.capture!.stopped, isTrue);
    });
  });

  group('audio errors', () {
    test('permission denied → failed(permissionDenied), nothing recorded', () async {
      final rig = await Rig.create(audio: FakeAudioSource(permission: false, grantsOnRequest: false));
      await rig.controller.start();
      final s = rig.controller.state as DictationFailed;
      expect(s.audioError, AudioSourceError.permissionDenied);
      expect(s.canRetry, isFalse);
      expect(s.message, isNotEmpty);
      expect(rig.audio.requestCount, 1);
      expect(rig.audio.startCount, 0);
      expect(rig.files, isEmpty);
    });

    test('permission granted on request proceeds', () async {
      final rig = await Rig.create(audio: FakeAudioSource(permission: false, grantsOnRequest: true));
      await rig.controller.start();
      expect(rig.controller.state, isA<DictationListening>());
      expect(rig.audio.requestCount, 1);
    });

    test('AudioSourceException from start → failed with that error, vault cleaned', () async {
      final rig = await Rig.create(
        audio: FakeAudioSource(startError: const AudioSourceException(AudioSourceError.backendMissing)),
      );
      await rig.controller.start();
      final s = rig.controller.state as DictationFailed;
      expect(s.audioError, AudioSourceError.backendMissing);
      expect(rig.files, isEmpty);
      expect(await rig.vault.pending(), isEmpty);
    });

    test('any other start error → failed(deviceUnavailable)', () async {
      final rig = await Rig.create(audio: FakeAudioSource(startError: StateError('boom')));
      await rig.controller.start();
      final s = rig.controller.state as DictationFailed;
      expect(s.audioError, AudioSourceError.deviceUnavailable);
      expect(rig.files, isEmpty);
    });

    test('can start again after a failed start', () async {
      final audio = FakeAudioSource(startError: StateError('boom'));
      final rig = await Rig.create(audio: audio);
      await rig.controller.start();
      audio.startError = null;
      await rig.controller.toggle();
      expect(rig.controller.state, isA<DictationListening>());
    });
  });

  group('short recordings and cancel', () {
    test('too-short recording → idle with a notice, file deleted, engine untouched', () async {
      final rig = await Rig.create();
      await rig.controller.start();
      rig.audio.capture!.emit(tonePcm(const Duration(milliseconds: 100)));
      await rig.pump();
      await rig.controller.stop();
      final s = rig.controller.state as DictationIdle;
      expect(s.notice, isNotNull);
      expect(rig.files, isEmpty);
      expect(rig.primary.requests, isEmpty);
      expect(rig.outcomes, isEmpty);
    });

    test('a recording of exactly minSpeech is processed', () async {
      final rig = await Rig.create();
      await rig.controller.start();
      rig.audio.capture!.emit(tonePcm(const Duration(milliseconds: 400)));
      await rig.pump();
      await rig.controller.stop();
      expect(rig.controller.state, isA<DictationDone>());
    });

    test('cancel while listening discards the audio', () async {
      final rig = await Rig.create();
      await rig.controller.start();
      await rig.speak(2);
      expect(rig.files, isNotEmpty);
      await rig.controller.cancel();
      expect(rig.controller.state, isA<DictationIdle>());
      expect((rig.controller.state as DictationIdle).notice, isNull);
      expect(rig.files, isEmpty);
      expect(rig.audio.capture!.stopped, isTrue);
      expect(rig.primary.requests, isEmpty);
    });

    test('cancel when idle is a no-op', () async {
      final rig = await Rig.create();
      await rig.controller.cancel();
      expect(rig.states, isEmpty);
    });

    test('can dictate again after a cancel', () async {
      final rig = await Rig.create();
      await rig.controller.start();
      await rig.controller.cancel();
      await rig.controller.start();
      await rig.speak(1);
      await rig.controller.stop();
      expect(rig.controller.state, isA<DictationDone>());
    });
  });

  group('stopping', () {
    test('blocks that arrive during stop are kept', () async {
      final rig = await Rig.create();
      await rig.controller.start();
      final cap = rig.audio.capture!;
      cap.onStop = (c) {
        c.emit(tonePcm(_second));
        c.emit(tonePcm(_second));
      };
      await rig.speak(2);
      await rig.controller.stop();
      final done = rig.controller.state as DictationDone;
      expect(done.outcome.duration, const Duration(seconds: 4));
      expect(rig.primary.requests.single.pcm.length, 4 * Pcm.bytesPerSecond);
    });

    test('total bytes match every block emitted', () async {
      final rig = await Rig.create();
      await rig.controller.start();
      final blocks = [
        tonePcm(const Duration(milliseconds: 130)),
        tonePcm(const Duration(milliseconds: 570)),
        silencePcm(const Duration(milliseconds: 300)),
      ];
      for (final b in blocks) {
        rig.audio.capture!.emit(b);
      }
      await rig.pump();
      await rig.controller.stop();
      expect(rig.primary.requests.single.pcm, concatBytes(blocks));
    });

    test('stop when not listening does nothing', () async {
      final rig = await Rig.create();
      await rig.controller.stop();
      expect(rig.states, isEmpty);
    });

    test('a stream error ends capture without hanging', () async {
      final rig = await Rig.create();
      await rig.controller.start();
      await rig.speak(1);
      rig.audio.capture!.emitError(StateError('mic gone'));
      await rig.pump();
      await rig.controller.stop();
      expect(rig.controller.state, isA<DictationDone>());
    });
  });

  group('toggle and re-entrancy', () {
    test('toggle starts, then stops and processes', () async {
      final rig = await Rig.create();
      await rig.controller.toggle();
      expect(rig.controller.state, isA<DictationListening>());
      await rig.speak(1);
      await rig.controller.toggle();
      expect(rig.controller.state, isA<DictationDone>());
      await rig.controller.toggle();
      expect(rig.controller.state, isA<DictationListening>());
      expect(rig.audio.startCount, 2);
    });

    test('no second start while starting or listening', () async {
      final rig = await Rig.create();
      final a = rig.controller.start();
      final b = rig.controller.start();
      await Future.wait([a, b]);
      await rig.controller.start();
      expect(rig.audio.startCount, 1);
    });

    test('start during processing is ignored', () async {
      final gate = Completer<String>();
      final engine = FakeCleanupEngine(script: [(CleanupRequest _) => gate.future]);
      final rig = await Rig.create(primary: engine);
      await rig.controller.start();
      await rig.speak(1);
      final stopping = rig.controller.stop();
      await rig.pump();
      expect(rig.controller.state, isA<DictationProcessing>());

      await rig.controller.start();
      expect(rig.audio.startCount, 1);
      expect(rig.controller.state, isA<DictationProcessing>());

      gate.complete('late result');
      await stopping;
      expect((rig.controller.state as DictationDone).outcome.text, 'late result');
    });
  });

  group('engine failure and retry', () {
    CleanupFailure server() => const CleanupFailure(
          CleanupFailureKind.server,
          'Gemini is having problems (503).',
          retryAfter: Duration(seconds: 12),
        );

    test('failure keeps the recording pending and allows retry', () async {
      final engine = FakeCleanupEngine(script: [server()], defaultResult: 'Second time lucky.');
      final rig = await Rig.create(primary: engine);
      await rig.controller.start();
      await rig.speak(2);
      await rig.controller.stop();

      final failed = rig.controller.state as DictationFailed;
      expect(failed.kind, CleanupFailureKind.server);
      expect(failed.message, contains('503'));
      expect(failed.retryAfter, const Duration(seconds: 12));
      expect(failed.canRetry, isTrue);
      expect(failed.recordingId, isNotNull);
      expect(await rig.vault.pending(), [failed.recordingId]);
      expect(rig.outcomes, isEmpty);

      await rig.controller.retry();

      final done = rig.controller.state as DictationDone;
      expect(done.outcome.text, 'Second time lucky.');
      expect(done.outcome.recordingId, failed.recordingId);
      expect(done.outcome.duration, const Duration(seconds: 2));
      expect(await rig.vault.pending(), isEmpty);
      expect(rig.outcomes, hasLength(1));
      expect(engine.requests, hasLength(2));
      expect(engine.requests.last.pcm.length, 2 * Pcm.bytesPerSecond);
    });

    test('an unexpected exception becomes failed(unknown) with the recording kept', () async {
      final engine = FakeCleanupEngine(script: [StateError('weird')]);
      final rig = await Rig.create(primary: engine);
      await rig.controller.start();
      await rig.speak(1);
      await rig.controller.stop();
      final failed = rig.controller.state as DictationFailed;
      expect(failed.kind, CleanupFailureKind.unknown);
      expect(failed.canRetry, isTrue);
      expect(await rig.vault.pending(), hasLength(1));
    });

    test('an exception in onOutcome fails the dictation but keeps the audio', () async {
      final rig = await Rig.create(onOutcome: (_) async => throw StateError('db closed'));
      await rig.controller.start();
      await rig.speak(1);
      await rig.controller.stop();
      expect(rig.controller.state, isA<DictationFailed>());
      expect((rig.controller.state as DictationFailed).canRetry, isTrue);
    });

    test('retry with an explicit id processes a pending recording from a previous run', () async {
      final rig = await Rig.create();
      final sink = await rig.vault.begin(now: DateTime.fromMillisecondsSinceEpoch(5, isUtc: true));
      sink.add(tonePcm(_second));
      await sink.close();
      expect(await rig.vault.pending(), [sink.id]);

      await rig.controller.retry(sink.id);

      expect((rig.controller.state as DictationDone).outcome.recordingId, sink.id);
      expect(await rig.vault.pending(), isEmpty);
    });

    test('retry of a missing recording fails without an id', () async {
      final rig = await Rig.create();
      await rig.controller.retry('does-not-exist');
      final failed = rig.controller.state as DictationFailed;
      expect(failed.canRetry, isFalse);
    });

    test('retry without an id outside failed state does nothing', () async {
      final rig = await Rig.create();
      await rig.controller.retry();
      expect(rig.states, isEmpty);
    });

    test('rate limited primary falls back and the outcome says so', () async {
      final primary = FakeCleanupEngine(script: [const CleanupFailure(CleanupFailureKind.rateLimited, 'slow')]);
      final fallback = FakeCleanupEngine(kind: EngineKind.onDevice, defaultResult: 'Local text.');
      final rig = await Rig.create(primary: primary, fallback: fallback);
      await rig.controller.start();
      await rig.speak(1);
      await rig.controller.stop();
      final outcome = (rig.controller.state as DictationDone).outcome;
      expect(outcome.text, 'Local text.');
      expect(outcome.engine, EngineKind.onDevice);
      expect(outcome.fellBack, isTrue);
      expect(outcome.fallbackReason!.kind, CleanupFailureKind.rateLimited);
    });
  });

  group('cancel while cleaning up', () {
    test('tapping during processing cancels, keeps the recording, ignores the late result', () async {
      final gate = Completer<String>();
      final engine = FakeCleanupEngine(script: [(CleanupRequest _) => gate.future]);
      final rig = await Rig.create(primary: engine);
      await rig.controller.start();
      await rig.speak(2);
      unawaited(rig.controller.stop());
      await rig.next<DictationProcessing>();
      await rig.pump();

      await rig.controller.toggle(); // the tap on the animating mic
      expect(rig.controller.state, isA<DictationIdle>());
      expect(await rig.vault.pending(), hasLength(1), reason: 'recording kept for retry');

      gate.complete('Late text.');
      await rig.pump();
      expect(rig.controller.state, isA<DictationIdle>());
      expect(rig.outcomes, isEmpty);
    });
  });
}
