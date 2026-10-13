// SPDX-License-Identifier: GPL-3.0-or-later

/// Contact display names as spelling hints, so "Siobhan" is not heard as
/// "Shavon". Reading the address book is platform code; everything here is
/// pure.
library;

/// Most names put in a prompt.
const maxContactNames = 400;

const _maxNameLength = 60;

final _email = RegExp(r'@');
final _hasLetter = RegExp(r'\p{L}', unicode: true);

/// Whether [name] looks like a person or place worth spelling: not a bare
/// number or e-mail address, has a letter, is a sane length.
bool isUsableContactName(String name) {
  final n = name.trim();
  if (n.length < 2 || n.length > _maxNameLength) return false;
  if (_email.hasMatch(n)) return false;
  if (!_hasLetter.hasMatch(n)) return false;
  return true;
}

/// Cleans, filters, deduplicates (case-insensitive) and caps [raw] names.
/// Names with a given and a family name come first, then single names;
/// order inside each group is kept.
List<String> selectContactNames(
  Iterable<String> raw, {
  int max = maxContactNames,
}) {
  final seen = <String>{};
  final full = <String>[];
  final single = <String>[];
  for (final r in raw) {
    final n = r
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .replaceAll(RegExp(r'[{}<>`"“”]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (!isUsableContactName(n) || !seen.add(n.toLowerCase())) continue;
    (n.contains(' ') ? full : single).add(n);
  }
  return [...full, ...single].take(max).toList();
}

/// The prompt sentence for [names], or '' when there are none.
String describeContactNames(Iterable<String> names) {
  final list = selectContactNames(names);
  if (list.isEmpty) return '';
  return 'These people may be mentioned; spell their names like this: ${list.join(', ')}.';
}

/// Reads display names from an address book.
abstract interface class ContactNameSource {
  Future<List<String>> names();
}

/// Caches [source] for [ttl] (an address book is slow and rarely changes) and
/// never throws: a failing source yields the last list, or none.
class ContactNamesCache {
  ContactNamesCache(
    this.source, {
    this.ttl = const Duration(hours: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ContactNameSource source;
  final Duration ttl;
  final DateTime Function() _clock;

  List<String> _names = const [];
  DateTime? _fetchedAt;
  Future<List<String>>? _loading;

  Future<List<String>> get() {
    final at = _fetchedAt;
    if (at != null && _clock().difference(at) < ttl)
      return Future.value(_names);
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<List<String>> _load() async {
    try {
      _names = selectContactNames(await source.names());
    } catch (_) {
      // Keep whatever we had; retry on the next request after the ttl.
    }
    _fetchedAt = _clock();
    return _names;
  }

  void invalidate() => _fetchedAt = null;
}
