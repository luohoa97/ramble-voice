// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/cleanup/cleanup_prompt.dart';
import 'package:ramble_voice/core/audio/pcm.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/cleanup/cleanup_pipeline.dart';
import 'package:ramble_voice/core/style/style_profile.dart';

import '../fakes/fake_cleanup_engine.dart';
import '../fakes/pcm_fixtures.dart';

const _style = StyleProfile(vocabulary: ['Ramble']);

/// 25 s of speech with a pause every ~4 s.
Uint8List _longSpeech() => concatBytes([
  for (var i = 0; i < 6; i++) ...[
    tonePcm(const Duration(seconds: 3, milliseconds: 500)),
    silencePcm(const Duration(milliseconds: 700)),
  ],
]);

CleanupFailure _fail(CleanupFailureKind k, [Duration? retry]) =>
    CleanupFailure(k, 'fail $k', retryAfter: retry);

void main() {
  const pipeline = CleanupPipeline(condition: CleanupPipeline.unconditioned);

  group('chunking and stitching', () {
    test('short audio is one request with the exact bytes', () async {
      final pcm = tonePcm(const Duration(seconds: 3));
      final engine = FakeCleanupEngine(script: ['Hello there.']);
      final r = await pipeline.run(pcm: pcm, style: _style, primary: engine);
      expect(r.text, 'Hello there.');
      expect(r.chunks, 1);
      expect(r.engine, EngineKind.gemini);
      expect(r.fellBack, isFalse);
      expect(engine.requests.single.pcm, pcm);
      expect(engine.styles.single, _style);
      expect(engine.modes.single, CleanupMode.clean);
    });

    test(
      'splits to the engine limit, covers the input, stitches in order',
      () async {
        final pcm = _longSpeech();
        final engine = FakeCleanupEngine(
          maxAudioPerRequest: const Duration(seconds: 10),
          script: ['one.', 'two.', 'three.', 'four.'],
        );
        final r = await pipeline.run(pcm: pcm, style: _style, primary: engine);
        expect(engine.requests.length, greaterThanOrEqualTo(3));
        expect(engine.pcmLengths.reduce((a, b) => a + b), pcm.length);
        for (final len in engine.pcmLengths) {
          expect(
            Pcm.durationOf(len),
            lessThanOrEqualTo(const Duration(seconds: 10)),
          );
        }
        expect(r.chunks, engine.requests.length);
        expect(
          r.text,
          [
            'one.',
            'two.',
            'three.',
            'four.',
          ].take(engine.requests.length).join(' '),
        );
      },
    );

    test('field context: first chunk gets the field text, later chunks the text written so far', () async {
      final engine = FakeCleanupEngine(
        maxAudioPerRequest: const Duration(seconds: 10),
        script: ['one.', 'two.', 'three.', 'four.'],
      );
      await pipeline.run(
        pcm: _longSpeech(),
        style: _style,
        primary: engine,
        contextBefore: 'Dear Sam,',
        contextAfter: 'Thanks',
      );
      final n = engine.requests.length;
      expect(n, greaterThanOrEqualTo(3));
      expect(engine.requests[0].contextBefore, 'Dear Sam,');
      expect(engine.requests[1].contextBefore, 'Dear Sam, one.');
      expect(engine.requests[2].contextBefore, 'Dear Sam, one. two.');
      expect(
        [for (final r in engine.requests) r.contextAfter],
        [...List.filled(n - 1, null), 'Thanks'],
      );
    });

    test(
      'without field context later chunks still continue the previous chunk',
      () async {
        final engine = FakeCleanupEngine(
          maxAudioPerRequest: const Duration(seconds: 10),
          script: ['one.', 'two.', 'three.', 'four.'],
        );
        await pipeline.run(pcm: _longSpeech(), style: _style, primary: engine);
        expect(engine.requests[0].contextBefore, isNull);
        expect(engine.requests[1].contextBefore, 'one.');
        expect(engine.requests[0].hasContext, isFalse);
        expect(engine.requests[1].hasContext, isTrue);
      },
    );

    test('context is passed to the fallback engine too', () async {
      final primary = FakeCleanupEngine(
        script: [_fail(CleanupFailureKind.noNetwork)],
      );
      final fallback = FakeCleanupEngine(kind: EngineKind.onDevice);
      await pipeline.run(
        pcm: tonePcm(const Duration(seconds: 1)),
        style: _style,
        primary: primary,
        fallback: fallback,
        contextBefore: 'Hi',
      );
      expect(fallback.requests.single.contextBefore, 'Hi');
    });

    test('passes verbatim mode through', () async {
      final engine = FakeCleanupEngine();
      await pipeline.run(
        pcm: tonePcm(const Duration(seconds: 1)),
        style: _style,
        primary: engine,
        mode: CleanupMode.verbatim,
      );
      expect(engine.modes, [CleanupMode.verbatim]);
    });

    test('reports progress per chunk, 1-based', () async {
      final engine = FakeCleanupEngine(
        maxAudioPerRequest: const Duration(seconds: 10),
      );
      final seen = <PipelineProgress>[];
      final r = await pipeline.run(
        pcm: _longSpeech(),
        style: _style,
        primary: engine,
        onProgress: seen.add,
      );
      expect(seen.map((p) => p.chunk), [for (var i = 1; i <= r.chunks; i++) i]);
      expect(
        seen.every(
          (p) =>
              p.chunks == r.chunks &&
              p.engine == EngineKind.gemini &&
              !p.fellBack,
        ),
        isTrue,
      );
    });
  });

  group('empty results', () {
    test('empty recording is emptyResult and no request is made', () async {
      final engine = FakeCleanupEngine();
      await expectLater(
        pipeline.run(pcm: Uint8List(0), style: _style, primary: engine),
        throwsA(
          isA<CleanupFailure>().having(
            (f) => f.kind,
            'kind',
            CleanupFailureKind.emptyResult,
          ),
        ),
      );
      expect(engine.requests, isEmpty);
    });

    test('all-empty text is emptyResult', () async {
      final engine = FakeCleanupEngine(script: ['  ']);
      await expectLater(
        pipeline.run(
          pcm: tonePcm(const Duration(seconds: 1)),
          style: _style,
          primary: engine,
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

  group('fallback', () {
    for (final kind in [
      CleanupFailureKind.rateLimited,
      CleanupFailureKind.noNetwork,
      CleanupFailureKind.dailyQuotaExceeded,
      CleanupFailureKind.server,
      CleanupFailureKind.audioTooLong,
    ]) {
      test('$kind on the primary uses the fallback and records why', () async {
        final primary = FakeCleanupEngine(script: [_fail(kind)]);
        final fallback = FakeCleanupEngine(
          kind: EngineKind.onDevice,
          script: ['from gemma'],
        );
        final pcm = tonePcm(const Duration(seconds: 2));
        final r = await pipeline.run(
          pcm: pcm,
          style: _style,
          primary: primary,
          fallback: fallback,
        );
        expect(r.text, 'from gemma');
        expect(r.engine, EngineKind.onDevice);
        expect(r.fellBack, isTrue);
        expect(r.fallbackReason!.kind, kind);
        expect(fallback.requests.single.pcm, pcm);
      });
    }

    test('fallback progress is flagged fellBack', () async {
      final primary = FakeCleanupEngine(
        script: [_fail(CleanupFailureKind.noNetwork)],
      );
      final fallback = FakeCleanupEngine(
        kind: EngineKind.onDevice,
        maxAudioPerRequest: const Duration(seconds: 10),
      );
      final seen = <PipelineProgress>[];
      final r = await pipeline.run(
        pcm: _longSpeech(),
        style: _style,
        primary: primary,
        fallback: fallback,
        onProgress: seen.add,
      );
      expect(r.chunks, greaterThan(1));
      expect(seen.first.engine, EngineKind.gemini);
      expect(seen.first.fellBack, isFalse);
      expect(seen.last.engine, EngineKind.onDevice);
      expect(seen.last.fellBack, isTrue);
    });

    test('a failure partway through a long recording falls back for the whole recording', () async {
      final primary = FakeCleanupEngine(
        maxAudioPerRequest: const Duration(seconds: 10),
        script: ['first chunk', _fail(CleanupFailureKind.rateLimited)],
      );
      final fallback = FakeCleanupEngine(
        kind: EngineKind.onDevice,
        maxAudioPerRequest: const Duration(seconds: 28),
      );
      final pcm = _longSpeech();
      final r = await pipeline.run(
        pcm: pcm,
        style: _style,
        primary: primary,
        fallback: fallback,
      );
      expect(r.engine, EngineKind.onDevice);
      expect(r.text, fallback.defaultResult);
      expect(fallback.pcmLengths.reduce((a, b) => a + b), pcm.length);
    });

    for (final kind in [
      CleanupFailureKind.invalidApiKey,
      CleanupFailureKind.blocked,
      CleanupFailureKind.missingApiKey,
    ]) {
      test('$kind is rethrown without trying the fallback', () async {
        final primary = FakeCleanupEngine(script: [_fail(kind)]);
        final fallback = FakeCleanupEngine(kind: EngineKind.onDevice);
        await expectLater(
          pipeline.run(
            pcm: tonePcm(const Duration(seconds: 1)),
            style: _style,
            primary: primary,
            fallback: fallback,
          ),
          throwsA(isA<CleanupFailure>().having((f) => f.kind, 'kind', kind)),
        );
        expect(fallback.requests, isEmpty);
      });
    }

    test('fallback not ready rethrows the original failure', () async {
      final primary = FakeCleanupEngine(
        script: [
          _fail(CleanupFailureKind.rateLimited, const Duration(seconds: 17)),
        ],
      );
      final fallback = FakeCleanupEngine(
        kind: EngineKind.onDevice,
        ready: const EngineNotReady(
          CleanupFailureKind.modelNotDownloaded,
          'no model',
        ),
      );
      await expectLater(
        pipeline.run(
          pcm: tonePcm(const Duration(seconds: 1)),
          style: _style,
          primary: primary,
          fallback: fallback,
        ),
        throwsA(
          isA<CleanupFailure>()
              .having((f) => f.kind, 'kind', CleanupFailureKind.rateLimited)
              .having(
                (f) => f.retryAfter,
                'retryAfter',
                const Duration(seconds: 17),
              ),
        ),
      );
      expect(fallback.requests, isEmpty);
    });

    test('no fallback configured rethrows', () async {
      final primary = FakeCleanupEngine(
        script: [_fail(CleanupFailureKind.noNetwork)],
      );
      await expectLater(
        pipeline.run(
          pcm: tonePcm(const Duration(seconds: 1)),
          style: _style,
          primary: primary,
        ),
        throwsA(
          isA<CleanupFailure>().having(
            (f) => f.kind,
            'kind',
            CleanupFailureKind.noNetwork,
          ),
        ),
      );
    });

    test('a fallback of the same kind is never used', () async {
      final primary = FakeCleanupEngine(
        kind: EngineKind.onDevice,
        script: [_fail(CleanupFailureKind.server)],
      );
      final fallback = FakeCleanupEngine(kind: EngineKind.onDevice);
      await expectLater(
        pipeline.run(
          pcm: tonePcm(const Duration(seconds: 1)),
          style: _style,
          primary: primary,
          fallback: fallback,
        ),
        throwsA(isA<CleanupFailure>()),
      );
      expect(fallback.requests, isEmpty);
    });

    test('when the fallback also fails, its failure propagates', () async {
      final primary = FakeCleanupEngine(
        script: [_fail(CleanupFailureKind.noNetwork)],
      );
      final fallback = FakeCleanupEngine(
        kind: EngineKind.onDevice,
        script: [_fail(CleanupFailureKind.outOfMemory)],
      );
      await expectLater(
        pipeline.run(
          pcm: tonePcm(const Duration(seconds: 1)),
          style: _style,
          primary: primary,
          fallback: fallback,
        ),
        throwsA(
          isA<CleanupFailure>().having(
            (f) => f.kind,
            'kind',
            CleanupFailureKind.outOfMemory,
          ),
        ),
      );
    });
  });

  group('CleanupFailureKind', () {
    test('cloudFallbackEligible and retryable sets', () {
      expect(
        CleanupFailureKind.values.where((k) => k.cloudFallbackEligible).toSet(),
        {
          CleanupFailureKind.rateLimited,
          CleanupFailureKind.dailyQuotaExceeded,
          CleanupFailureKind.modelNotOnFreeTier,
          CleanupFailureKind.modelUnavailable,
          CleanupFailureKind.noNetwork,
          CleanupFailureKind.timedOut,
          CleanupFailureKind.server,
          CleanupFailureKind.audioTooLong,
        },
      );
      expect(CleanupFailureKind.values.where((k) => k.retryable).toSet(), {
        CleanupFailureKind.rateLimited,
        CleanupFailureKind.noNetwork,
        CleanupFailureKind.timedOut,
        CleanupFailureKind.server,
        CleanupFailureKind.outOfMemory,
        CleanupFailureKind.unknown,
      });
    });
  });

  test('a cut inside speech: the cut-off word is heard again, not duplicated, and the part continues', () async {
    final engine = FakeCleanupEngine(
      maxAudioPerRequest: const Duration(seconds: 10),
      script: ['We should meet on Tues', 'on Tuesday at three, I think.'],
    );
    final result =
        await const CleanupPipeline(condition: CleanupPipeline.unconditioned)
            .run(
              pcm: tonePcm(const Duration(seconds: 15)),
              style: const StyleProfile(),
              primary: engine,
              contextBefore: 'Plan:',
            );
    final second = engine.requests[1];
    expect(second.part, 2);
    expect(second.repeated.inMilliseconds, greaterThan(1500));
    // The fragment "Tues" is not context; the overlap re-hears it.
    expect(second.contextBefore, 'Plan: We should meet on');
    expect(result.text, 'We should meet on Tuesday at three, I think.');
    expect(
      CleanupPrompt.systemFor(second),
      contains('part 2 of one long recording'),
    );
  });
}
