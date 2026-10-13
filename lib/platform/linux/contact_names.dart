// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../core/style/contact_names.dart';

/// Reads display names, read-only, from the address books GNOME Contacts and
/// Evolution keep through Evolution Data Server: the local book
/// (`~/.local/share/evolution/addressbook/<id>/contacts.db`) and the caches of
/// online books (`~/.cache/evolution/addressbook/<id>/cache.db`). Both use a
/// table named after the folder (`folder_id`) with `full_name`, `given_name`,
/// `family_name` and `file_as` columns.
///
/// KDE (Akonadi/KAddressBook) is not supported yet.
class EvolutionContactNames implements ContactNameSource {
  /// Reads the current user's books. With [home] given, only that directory
  /// is used (for tests); otherwise `XDG_DATA_HOME` / `XDG_CACHE_HOME` apply.
  EvolutionContactNames({String? home})
      : _data = _dir(home, 'XDG_DATA_HOME', ['.local', 'share']),
        _cache = _dir(home, 'XDG_CACHE_HOME', ['.cache']);

  final String? _data;
  final String? _cache;

  static String? _dir(String? home, String xdg, List<String> fallback) {
    if (home != null) return p.joinAll([home, ...fallback]);
    final env = Platform.environment;
    final x = env[xdg];
    if (x != null && x.isNotEmpty) return x;
    final h = env['HOME'];
    return h == null ? null : p.joinAll([h, ...fallback]);
  }

  List<File> _databases() {
    final out = <File>[];
    for (final (base, file) in [(_data, 'contacts.db'), (_cache, 'cache.db')]) {
      if (base == null) continue;
      final root = Directory(p.join(base, 'evolution', 'addressbook'));
      if (!root.existsSync()) continue;
      for (final book in root.listSync().whereType<Directory>()) {
        final db = File(p.join(book.path, file));
        if (db.existsSync()) out.add(db);
      }
    }
    return out;
  }

  @override
  Future<List<String>> names() async {
    final names = <String>[];
    for (final file in _databases()) {
      Database? db;
      try {
        db = sqlite3.open(file.path, mode: OpenMode.readOnly);
        names.addAll(readNames(db));
      } catch (_) {
        // A locked or unexpected database is skipped.
      } finally {
        db?.close();
      }
    }
    return names;
  }

  /// Display names from an open address-book database, skipping contact lists.
  static List<String> readNames(Database db) {
    final rows = db.select(
      "SELECT full_name, given_name, family_name, file_as FROM folder_id WHERE COALESCE(is_list, 0) = 0",
    );
    String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    return [
      for (final r in rows)
        text(r['full_name']) ??
            text([text(r['given_name']), text(r['family_name'])].whereType<String>().join(' ')) ??
            text(r['file_as']) ??
            '',
    ].where((n) => n.isNotEmpty).toList();
  }
}
