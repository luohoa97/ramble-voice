// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_models.dart';

import '../fakes/gemini_fakes.dart';

List<String> _ids(List<Map<String, Object?>> raw) =>
    GeminiModelSelector.parse(raw).map((m) => m.id).toList();

GeminiModelInfo? _pick(List<Map<String, Object?>> raw, {String? preferred}) =>
    GeminiModelSelector.choose(
      GeminiModelSelector.parse(raw),
      preferred: preferred,
    );

void main() {
  group('parse', () {
    test('keeps pro, flash and flash-lite text models', () {
      expect(
        _ids(realisticModels()),
        containsAll([
          'gemini-3.5-pro',
          'gemini-3.8-flash',
          'gemini-3.5-flash-lite',
          'gemini-3.5-flash-lite-preview-09-2026',
          'gemini-3.1-flash-lite',
          'gemini-2.5-flash',
          'gemini-2.5-flash-lite',
          'gemini-flash-latest',
          'gemini-flash-lite-latest',
        ]),
      );
      expect(
        _ids(realisticModels()),
        isNot(contains('gemini-3.5-flash-lite-tts')),
      );
      expect(_ids(realisticModels()), isNot(contains('gemini-3.9-flash-lite')));
    });

    test(
      'orders by tier, then alias, then version, then stable before preview',
      () {
        final ids = _ids(realisticModels());
        expect(
          ids.indexOf('gemini-3.5-pro'),
          lessThan(ids.indexOf('gemini-flash-latest')),
        );
        expect(
          ids.indexOf('gemini-flash-latest'),
          lessThan(ids.indexOf('gemini-3.8-flash')),
        );
        expect(
          ids.indexOf('gemini-3.8-flash'),
          lessThan(ids.indexOf('gemini-3-flash-preview')),
        );
        expect(
          ids.indexOf('gemini-3-flash-preview'),
          lessThan(ids.indexOf('gemini-2.5-flash')),
        );
        expect(
          ids.indexOf('gemini-2.5-flash'),
          lessThan(ids.indexOf('gemini-flash-lite-latest')),
        );
        expect(
          ids.indexOf('gemini-flash-lite-latest'),
          lessThan(ids.indexOf('gemini-3.5-flash-lite')),
        );
        expect(
          ids.indexOf('gemini-3.5-flash-lite'),
          lessThan(ids.indexOf('gemini-3.5-flash-lite-preview-09-2026')),
        );
        expect(
          ids.indexOf('gemini-3.5-flash-lite-preview-09-2026'),
          lessThan(ids.indexOf('gemini-3.1-flash-lite')),
        );
      },
    );

    test('excludes tts, live, image, audio, embedding, omni and models without generateContent', () {
      final ids = _ids([
        modelEntry('gemini-3.5-flash-lite-tts'),
        modelEntry('gemini-3.5-flash-lite-live'),
        modelEntry('gemini-3.5-flash-image'),
        modelEntry('gemini-3.5-flash-native-audio-dialog'),
        modelEntry('gemini-omni-1.1-flash'),
        modelEntry('gemini-2.5-computer-use-preview-10-2025'),
        modelEntry('gemini-robotics-er-1.5-preview'),
        modelEntry('gemini-embedding-001', methods: ['embedContent']),
        modelEntry('gemini-4.0-flash-lite', methods: ['countTokens']),
      ]);
      expect(ids, isEmpty);
      expect(_ids(realisticModels()), isNot(contains('gemini-omni-1.1-flash')));
      expect(
        _ids(realisticModels()),
        isNot(contains('gemini-2.5-flash-image')),
      );
    });

    test('parses family, tier label, version, preview flag and metadata', () {
      final m = {
        for (final x in GeminiModelSelector.parse([
          modelEntry(
            'gemini-3.5-flash-lite-preview-09-2026',
            displayName: 'Preview',
          ),
          modelEntry('gemini-4-pro'),
          modelEntry('gemini-3-flash-preview'),
          modelEntry('gemini-flash-latest'),
        ]))
          x.id: x,
      };
      final lite = m['gemini-3.5-flash-lite-preview-09-2026']!;
      expect(lite.family, GeminiFamily.flashLite);
      expect(lite.tier, 'Flash-Lite');
      expect(lite.preview, isTrue);
      expect((lite.major, lite.minor), (3, 5));
      expect(lite.displayName, 'Preview');
      expect(lite.inputTokenLimit, 1048576);
      expect(m['gemini-4-pro']!.tier, 'Pro');
      expect(m['gemini-4-pro']!.version, 4.0);
      expect(m['gemini-3-flash-preview']!.preview, isTrue);
      expect(m['gemini-3-flash-preview']!.tier, 'Flash');
      expect(m['gemini-flash-latest']!.alias, isTrue);
    });

    test(
      'numeric revision suffixes are accepted and sort after the plain id',
      () {
        expect(
          _ids([
            modelEntry('gemini-2.5-flash-lite-001'),
            modelEntry('gemini-2.5-flash-lite'),
          ]),
          ['gemini-2.5-flash-lite', 'gemini-2.5-flash-lite-001'],
        );
      },
    );

    test('handles an empty or odd list', () {
      expect(GeminiModelSelector.parse(const []), isEmpty);
      expect(
        GeminiModelSelector.parse([
          {'name': 'models/gemini-3.5-flash'},
        ]),
        isEmpty,
      );
    });

    test('minor versions compare numerically (3.10 is above 3.9)', () {
      expect(
        _ids([modelEntry('gemini-3.9-flash'), modelEntry('gemini-3.10-flash')])
            .first,
        'gemini-3.10-flash',
      );
    });
  });

  group('choose', () {
    test('default is the newest stable flash, not an alias or preview', () {
      expect(_pick(realisticModels())!.id, 'gemini-3.8-flash');
    });

    test('falls back through preview flash, lite and pro', () {
      expect(
        _pick([
          modelEntry('gemini-3-flash-preview'),
          modelEntry('gemini-3.5-flash-lite'),
        ])!.id,
        'gemini-3-flash-preview',
      );
      expect(
        _pick([
          modelEntry('gemini-3.5-flash-lite'),
          modelEntry('gemini-3.5-pro'),
        ])!.id,
        'gemini-3.5-flash-lite',
      );
      expect(_pick([modelEntry('gemini-3.5-pro')])!.id, 'gemini-3.5-pro');
      expect(
        _pick([modelEntry('gemini-flash-latest')])!.id,
        'gemini-flash-latest',
      );
    });

    test(
      'any listed id is honoured, including older generations and aliases',
      () {
        for (final id in [
          'gemini-2.5-flash-lite',
          'gemini-3.5-pro',
          'gemini-flash-latest',
          'gemini-3.5-flash-lite-preview-09-2026',
        ]) {
          expect(_pick(realisticModels(), preferred: id)!.id, id);
        }
      },
    );

    test('unknown preferred id falls back to the default', () {
      expect(
        _pick(realisticModels(), preferred: 'nonsense')!.id,
        'gemini-3.8-flash',
      );
    });

    test('the default skips models without free-tier quota', () {
      final models = [
        for (final m in GeminiModelSelector.parse(realisticModels()))
          m.id == 'gemini-3.8-flash'
              ? m.copyWith(freeTierUnavailable: true)
              : m,
      ];
      // Goes to Flash-Lite rather than an older Flash.
      expect(
        GeminiModelSelector.defaultModel(models)!.id,
        'gemini-3.5-flash-lite',
      );
    });

    test('the default and the chain skip models marked unavailable', () {
      final models = [
        for (final m in GeminiModelSelector.parse(realisticModels()))
          m.id == 'gemini-3.5-flash-lite'
              ? m.copyWith(unavailableReason: 'retired')
              : m,
      ];
      final first = GeminiModelSelector.choose(
        models,
        preferred: 'gemini-3.5-flash-lite',
      )!;
      expect(first.unavailable, isTrue);
      expect(GeminiModelSelector.chain(models, first).map((m) => m.id), [
        'gemini-3.8-flash',
        'gemini-3.1-flash-lite',
      ]);
    });

    test('no usable models means null', () {
      expect(
        _pick([
          modelEntry('gemini-embedding-001', methods: ['embedContent']),
        ]),
        isNull,
      );
    });

    test('same result whatever the input order', () {
      expect(
        _pick(realisticModels().reversed.toList())!.id,
        'gemini-3.8-flash',
      );
    });
  });

  group('chain', () {
    test('first model, then the newest stable flash-lite', () {
      final models = GeminiModelSelector.parse(realisticModels());
      final first = GeminiModelSelector.choose(models)!;
      expect(GeminiModelSelector.chain(models, first).map((m) => m.id), [
        'gemini-3.8-flash',
        'gemini-3.5-flash-lite',
      ]);
    });

    test('no duplicate when the pick is already the flash-lite', () {
      final models = GeminiModelSelector.parse(realisticModels());
      final first = GeminiModelSelector.choose(
        models,
        preferred: 'gemini-3.5-flash-lite',
      )!;
      expect(GeminiModelSelector.chain(models, first).map((m) => m.id), [
        'gemini-3.5-flash-lite',
      ]);
    });

    test('no flash-lite listed means a single model', () {
      final models = GeminiModelSelector.parse([
        modelEntry('gemini-3.8-flash'),
      ]);
      expect(GeminiModelSelector.chain(models, models.first), hasLength(1));
    });
  });
}
