// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';
import 'package:ramble_voice/core/style/languages.dart';
import 'package:ramble_voice/core/style/snippets.dart';

void main() {
  group('Languages', () {
    test('has about 40 languages with unique codes and names', () {
      expect(Languages.all.length, inInclusiveRange(40, 45));
      expect({for (final l in Languages.all) l.code}, hasLength(Languages.all.length));
      expect({for (final l in Languages.all) l.name}, hasLength(Languages.all.length));
    });

    test('byCode handles regions, case and unknowns', () {
      expect(Languages.byCode('en')!.name, 'English');
      expect(Languages.byCode('pt-BR')!.name, 'Portuguese');
      expect(Languages.byCode('FR_ca')!.name, 'French');
      expect(Languages.byCode('auto'), isNull);
      expect(Languages.byCode(''), isNull);
      expect(Languages.byCode(null), isNull);
      expect(Languages.byCode('xx'), isNull);
    });

    test('describe', () {
      expect(
        Languages.describe(['en', 'zh']),
        'The speaker only uses these languages: English, Chinese (Mandarin). '
        'Write every word in the language it was spoken in; never translate and never switch a word into another language.',
      );
      expect(Languages.describe(['ja']), startsWith('The speaker only uses Japanese. Write every word'));
      expect(Languages.describe(const []), startsWith('Write in the language that is spoken'));
      expect(Languages.describe(['nonsense']), Languages.describe(const []));
      expect(Languages.describe(['en'], allowTranslation: true), contains('asks for a translation'));
    });

    test('normaliseList keeps known codes once, in order', () {
      expect(Languages.normaliseList(['es-MX', 'EN', 'es', 'zzz', null, '', 'auto']), ['es', 'en']);
    });
  });

  group('Snippet', () {
    test('json round trip', () {
      const s = Snippet(trigger: 'my email', expansion: 'x@y.com');
      expect(Snippet.fromJson(s.toJson()), s);
      expect(Snippet.fromJson(const {}).isUsable, isFalse);
    });

    test('normalise drops blanks, trims and dedupes by trigger', () {
      final out = normaliseSnippets(const [
        Snippet(trigger: ' My Email ', expansion: ' a@b.c '),
        Snippet(trigger: 'my email', expansion: 'other'),
        Snippet(trigger: 'x', expansion: ' '),
      ]);
      expect(out, [const Snippet(trigger: 'My Email', expansion: 'a@b.c')]);
    });

    test('describe is empty without usable snippets', () {
      expect(describeSnippetList(const []), '');
      expect(describeSnippetList(const [Snippet(trigger: '', expansion: 'a')]), '');
    });

    test('describe caps long values', () {
      final out = describeSnippetList([Snippet(trigger: 't', expansion: 'a' * 900)]);
      expect(out.length, lessThan(800));
    });
  });

  group('AppSettings', () {
    test('defaults', () {
      const s = AppSettings();
      expect(s.languages, isEmpty);
      expect(s.useContactNames, isFalse);
      expect(s.snippets, isEmpty);
    });

    test('json round trip keeps language and snippets', () {
      const s = AppSettings(languages: ['de', 'en'], useContactNames: true, snippets: [Snippet(trigger: 'sig', expansion: 'Best, Neil')]);
      final back = AppSettings.fromJson(s.toJson());
      expect(back.languages, ['de', 'en']);
      expect(back.useContactNames, isTrue);
      expect(back.snippets, s.snippets);
    });

    test('old files and junk load safely', () {
      final back = AppSettings.fromJson({'language': 'klingon', 'languages': 'x', 'snippets': 'nope'});
      expect(back.languages, isEmpty);
      expect(back.snippets, isEmpty);
      expect(AppSettings.fromJson({'snippets': [1, {'trigger': 'a', 'expansion': 'b'}]}).snippets, hasLength(1));
    });

    test('copyWith and effectiveStyle', () {
      final s = const AppSettings().copyWith(languages: ['fr'], snippets: const [Snippet(trigger: 'a', expansion: 'b')]);
      expect(s.effectiveStyle.languages, ['fr']);
      expect(s.effectiveStyle.snippets, s.snippets);
      expect(s.effectiveStyle.preset, s.style.preset);
      expect(s.copyWith().languages, ['fr']);
    });

    test('migrates the old single language', () {
      expect(AppSettings.fromJson({'language': 'de'}, deviceLanguages: ['en']).languages, ['de']);
      expect(AppSettings.fromJson({'language': 'auto'}, deviceLanguages: ['en', 'fr']).languages, ['en', 'fr']);
      expect(AppSettings.fromJson(const {}, deviceLanguages: ['en']).languages, ['en']);
      // An explicit empty list is "detect any" and is not replaced.
      expect(AppSettings.fromJson({'languages': <String>[]}, deviceLanguages: ['en']).languages, isEmpty);
    });
  });
}
