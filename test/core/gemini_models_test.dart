// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_models.dart';

import '../fakes/gemini_fakes.dart';

List<String> _ids(List<Map<String, Object?>> raw) =>
    GeminiModelSelector.liteModels(raw).map((m) => m.id).toList();

GeminiModelInfo? _pick(List<Map<String, Object?>> raw, {String? preferred}) =>
    GeminiModelSelector.choose(GeminiModelSelector.liteModels(raw), preferred: preferred);

void main() {
  group('liteModels', () {
    test('keeps only flash-lite text models that support generateContent', () {
      final ids = _ids(realisticModels());
      expect(ids, [
        'gemini-3.5-flash-lite',
        'gemini-3.5-flash-lite-preview-09-2026',
        'gemini-3.1-flash-lite',
        'gemini-2.5-flash-lite',
      ]);
    });

    test('excludes tts, live, audio, image, embedding and non-lite flash', () {
      final ids = _ids([
        modelEntry('gemini-3.5-flash-lite-tts'),
        modelEntry('gemini-3.5-flash-lite-live'),
        modelEntry('gemini-3.5-flash-lite-image'),
        modelEntry('gemini-3.5-flash-lite-native-audio-dialog'),
        modelEntry('gemini-3.8-flash'),
        modelEntry('gemini-embedding-001', methods: ['embedContent']),
        modelEntry('text-embedding-004', methods: ['embedContent']),
        modelEntry('gemini-4.0-flash-lite', methods: ['countTokens']),
      ]);
      expect(ids, isEmpty);
    });

    test('parses version, preview flag and metadata', () {
      final m = GeminiModelSelector.liteModels([
        modelEntry('gemini-3.5-flash-lite-preview-09-2026', displayName: 'Gemini 3.5 Flash-Lite Preview'),
        modelEntry('gemini-4-flash-lite'),
      ]);
      final byId = {for (final x in m) x.id: x};
      expect(byId['gemini-3.5-flash-lite-preview-09-2026']!.preview, isTrue);
      expect(byId['gemini-3.5-flash-lite-preview-09-2026']!.major, 3);
      expect(byId['gemini-3.5-flash-lite-preview-09-2026']!.minor, 5);
      expect(byId['gemini-3.5-flash-lite-preview-09-2026']!.displayName, 'Gemini 3.5 Flash-Lite Preview');
      expect(byId['gemini-3.5-flash-lite-preview-09-2026']!.inputTokenLimit, 1048576);
      expect(byId['gemini-4-flash-lite']!.version, 4.0);
      expect(byId['gemini-4-flash-lite']!.preview, isFalse);
    });

    test('numeric revision suffixes are accepted and sort after the alias', () {
      expect(_ids([modelEntry('gemini-2.5-flash-lite-001'), modelEntry('gemini-2.5-flash-lite')]),
          ['gemini-2.5-flash-lite', 'gemini-2.5-flash-lite-001']);
    });

    test('handles an empty or odd list', () {
      expect(GeminiModelSelector.liteModels(const []), isEmpty);
      expect(GeminiModelSelector.liteModels([{'name': 'models/gemini-3.5-flash-lite'}]), isEmpty);
    });

    test('minor versions compare numerically (3.10 is not below 3.9)', () {
      // Documents the version scheme: minor is divided by 100, so 3.10 > 3.9.
      final ids = _ids([modelEntry('gemini-3.9-flash-lite'), modelEntry('gemini-3.10-flash-lite')]);
      expect(ids.first, 'gemini-3.10-flash-lite');
    });
  });

  group('choose / latestGeneration', () {
    test('picks the newest generation, stable over preview', () {
      expect(_pick(realisticModels())!.id, 'gemini-3.5-flash-lite');
    });

    test('falls back to preview when no stable exists in the newest generation', () {
      final m = _pick([
        modelEntry('gemini-3.5-flash-lite-preview-09-2026'),
        modelEntry('gemini-3.1-flash-lite'),
      ]);
      expect(m!.id, 'gemini-3.5-flash-lite-preview-09-2026');
    });

    test('latestGeneration contains only the newest version', () {
      final latest = GeminiModelSelector.latestGeneration(GeminiModelSelector.liteModels(realisticModels()));
      expect(latest.map((m) => m.id), ['gemini-3.5-flash-lite', 'gemini-3.5-flash-lite-preview-09-2026']);
    });

    test('preferred id is honoured within the newest generation', () {
      expect(_pick(realisticModels(), preferred: 'gemini-3.5-flash-lite-preview-09-2026')!.id,
          'gemini-3.5-flash-lite-preview-09-2026');
    });

    test('preferred id from an older generation is ignored', () {
      expect(_pick(realisticModels(), preferred: 'gemini-2.5-flash-lite')!.id, 'gemini-3.5-flash-lite');
      expect(_pick(realisticModels(), preferred: 'gemini-3.1-flash-lite')!.id, 'gemini-3.5-flash-lite');
    });

    test('unknown preferred id falls back to the newest', () {
      expect(_pick(realisticModels(), preferred: 'nonsense')!.id, 'gemini-3.5-flash-lite');
    });

    test('never returns an older generation, whatever the input order', () {
      final models = realisticModels().reversed.toList();
      for (final pref in [null, 'gemini-2.5-flash-lite', 'gemini-3.1-flash-lite']) {
        expect(_pick(models, preferred: pref)!.version, closeTo(3.05, 1e-9));
      }
    });

    test('no lite models means null', () {
      expect(_pick([modelEntry('gemini-3.8-flash')]), isNull);
      expect(GeminiModelSelector.latestGeneration(const []), isEmpty);
    });
  });
}
