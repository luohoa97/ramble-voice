// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/style/contact_names.dart';
import 'package:ramble_voice/core/style/device_languages.dart';
import 'package:ramble_voice/core/style/style_profile.dart';
import 'package:ramble_voice/platform/linux/contact_names.dart';
import 'package:sqlite3/sqlite3.dart';

import '../fakes/temp_dirs.dart';

class _Source implements ContactNameSource {
  _Source(this.results);
  final List<Object> results;
  int calls = 0;

  @override
  Future<List<String>> names() async {
    final r = results[calls < results.length ? calls : results.length - 1];
    calls++;
    if (r is List<String>) return r;
    throw r;
  }
}

void main() {
  group('selectContactNames', () {
    test('drops numbers, e-mails, blanks and overlong junk; dedupes case-insensitively', () {
      expect(
        selectContactNames([
          'Neil Luo',
          'neil luo',
          '+61 400 000 000',
          'a@b.com',
          '  ',
          'x',
          '1234',
          'Siobhan',
          'A' * 80,
        ]),
        ['Neil Luo', 'Siobhan'],
      );
    });

    test('given+family names come first, order kept', () {
      expect(selectContactNames(['Mum', 'Ada Lovelace', 'Bob', 'Grace Hopper']), ['Ada Lovelace', 'Grace Hopper', 'Mum', 'Bob']);
    });

    test('is capped at 400 and keeps full names when over the cap', () {
      final raw = [for (var i = 0; i < 500; i++) 'Single${String.fromCharCodes([97 + i % 26, 97 + (i ~/ 26) % 26, 97 + (i ~/ 676) % 26])}'];
      final out = selectContactNames([...raw, 'Zed Last']);
      expect(out, hasLength(maxContactNames));
      expect(out.first, 'Zed Last');
    });

    test('strips characters that could fake prompt structure', () {
      expect(selectContactNames(['Ann <b>"Lee"</b>\nSmith {x}']), ['Ann bLee/b Smith x']);
    });

    test('works with non-latin names', () {
      expect(selectContactNames(['李雷', 'Zoë Müller']), ['Zoë Müller', '李雷']);
    });
  });

  group('describeContactNames', () {
    test('line and empty case', () {
      expect(describeContactNames(['Neil Luo', 'Mum']), 'These people may be mentioned; spell their names like this: Neil Luo, Mum.');
      expect(describeContactNames(['123', 'a@b.c']), '');
      expect(const StyleProfile(contactNames: ['Neil Luo']).describeContacts(), contains('Neil Luo'));
    });

    test('contact names take part in StyleProfile equality', () {
      expect(const StyleProfile(contactNames: ['A B']) == const StyleProfile(contactNames: ['A B']), isTrue);
      expect(const StyleProfile(contactNames: ['A B']) == const StyleProfile(), isFalse);
    });
  });

  group('ContactNamesCache', () {
    test('caches for the ttl, then reloads', () async {
      var now = DateTime(2026);
      final source = _Source([['Ada Lovelace'], ['Grace Hopper']]);
      final cache = ContactNamesCache(source, clock: () => now);
      expect(await cache.get(), ['Ada Lovelace']);
      now = now.add(const Duration(minutes: 59));
      expect(await cache.get(), ['Ada Lovelace']);
      expect(source.calls, 1);
      now = now.add(const Duration(minutes: 2));
      expect(await cache.get(), ['Grace Hopper']);
      expect(source.calls, 2);
    });

    test('concurrent callers share one read', () async {
      final source = _Source([['Ada Lovelace']]);
      final cache = ContactNamesCache(source);
      await Future.wait([cache.get(), cache.get(), cache.get()]);
      expect(source.calls, 1);
    });

    test('a failing source yields the previous list and never throws', () async {
      var now = DateTime(2026);
      final source = _Source([['Ada Lovelace'], StateError('locked')]);
      final cache = ContactNamesCache(source, clock: () => now);
      await cache.get();
      now = now.add(const Duration(hours: 2));
      expect(await cache.get(), ['Ada Lovelace']);
      expect(await ContactNamesCache(_Source([StateError('x')])).get(), isEmpty);
    });

    test('invalidate forces a reload', () async {
      final source = _Source([['A One'], ['B Two']]);
      final cache = ContactNamesCache(source);
      await cache.get();
      cache.invalidate();
      expect(await cache.get(), ['B Two']);
    });
  });

  group('EvolutionContactNames', () {
    Database book() {
      final db = sqlite3.openInMemory();
      db.execute('''CREATE TABLE folder_id (uid TEXT PRIMARY KEY, file_as TEXT, full_name TEXT, given_name TEXT,
          family_name TEXT, is_list INTEGER)''');
      return db;
    }

    test('reads full names, falls back to given+family then file_as, skips lists', () {
      final db = book()
        ..execute("INSERT INTO folder_id VALUES ('1','Luo, Neil','Neil Luo','Neil','Luo',0)")
        ..execute("INSERT INTO folder_id VALUES ('2','Ada','', 'Ada','Lovelace',NULL)")
        ..execute("INSERT INTO folder_id VALUES ('3','Mum',NULL,NULL,NULL,0)")
        ..execute("INSERT INTO folder_id VALUES ('4','Family',NULL,NULL,NULL,1)")
        ..execute("INSERT INTO folder_id VALUES ('5','',NULL,NULL,NULL,0)");
      expect(EvolutionContactNames.readNames(db), ['Neil Luo', 'Ada Lovelace', 'Mum']);
      db.close();
    });

    test('opens real database files read-only under the home directory', () async {
      final home = await makeTempDir();
      final dir = Directory('${home.path}/.local/share/evolution/addressbook/system')..createSync(recursive: true);
      final db = sqlite3.open('${dir.path}/contacts.db');
      db.execute('CREATE TABLE folder_id (uid TEXT PRIMARY KEY, file_as TEXT, full_name TEXT, given_name TEXT, family_name TEXT, is_list INTEGER)');
      db.execute("INSERT INTO folder_id VALUES ('1','x','Ada Lovelace','Ada','Lovelace',0)");
      db.close();
      // A broken second book is skipped.
      final bad = Directory('${home.path}/.local/share/evolution/addressbook/bad')..createSync(recursive: true);
      File('${bad.path}/contacts.db').writeAsStringSync('not a database');
      expect(await EvolutionContactNames(home: home.path).names(), ['Ada Lovelace']);
      expect(await EvolutionContactNames(home: '${home.path}/missing').names(), isEmpty);
    });
  });

  group('languagesFromLocales', () {
    test('parses POSIX and BCP-47 locales, dedupes, keeps known languages', () {
      expect(languagesFromLocales(['en_AU.UTF-8']), ['en']);
      expect(languagesFromLocales(['de_DE:fr_FR:en']), ['de', 'fr', 'en']);
      expect(languagesFromLocales(['zh-Hans-CN', 'zh_TW', 'C', 'POSIX', '', 'xx_YY']), ['zh']);
      expect(languagesFromLocales(['en_US', 'fr', 'de', 'es']), ['en', 'fr', 'de'], reason: 'capped at three');
    });
  });
}
