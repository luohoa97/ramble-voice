// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/history/history_db.dart';
import 'package:ramble_voice/core/history/vocabulary_suggestions.dart';

void main() {
  group('suggestVocabulary', () {
    test('suggests names and technical tokens the user introduced', () {
      expect(
        suggestVocabulary(
          'we deploy on cube ernetes with get hub for neil',
          'We deploy on Kubernetes with GitHub for Neil.',
        ),
        ['Kubernetes', 'GitHub', 'Neil'],
      );
    });

    test('ignores plain words and sentence-initial capitals', () {
      expect(
        suggestVocabulary(
          'i think so. we go',
          'I think so. We should go. Then leave.',
        ),
        isEmpty,
      );
    });

    test('ignores tokens already present', () {
      expect(
        suggestVocabulary('Ask Neil about it', 'Ask Neil about it now'),
        isEmpty,
      );
    });

    test('suggests case corrections in the middle of a sentence', () {
      expect(suggestVocabulary('use kubernetes here', 'use Kubernetes here'), [
        'Kubernetes',
      ]);
    });

    test('finds digits, dots and underscores', () {
      expect(
        suggestVocabulary(
          'edit the config',
          'edit package.json and snake_case.py with gpt4',
        ),
        ['package.json', 'snake_case.py', 'gpt4'],
      );
    });

    test('deduplicates case-insensitively and drops possessives', () {
      expect(suggestVocabulary('hi', "hi from Neil and NEIL, Neil's cat"), [
        'Neil',
      ]);
    });

    test('respects max and handles empty input', () {
      expect(suggestVocabulary('', ''), isEmpty);
      expect(suggestVocabulary('a', 'a B1 C2 D3 E4', max: 2), ['B1', 'C2']);
    });

    test('works with non-latin letters', () {
      expect(suggestVocabulary('hallo', 'hallo Zoë und Müller'), [
        'Zoë',
        'Müller',
      ]);
    });
  });

  group('HistoryDb.updateCleaned', () {
    late HistoryDb db;
    setUp(() => db = HistoryDb(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('replaces the cleaned text only', () async {
      await db.upsert(
        HistoryEntriesCompanion.insert(
          id: 'a',
          createdAt: DateTime.utc(2026),
          durationMs: 1,
          cleaned: 'old',
          verbatim: const Value('raw'),
          engine: 'gemini',
        ),
      );
      expect(await db.updateCleaned('a', 'new'), isTrue);
      final e = (await db.byId('a'))!;
      expect(e.cleaned, 'new');
      expect(e.verbatim, 'raw');
      expect(await db.updateCleaned('missing', 'x'), isFalse);
    });
  });
}
