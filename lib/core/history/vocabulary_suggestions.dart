// SPDX-License-Identifier: GPL-3.0-or-later

/// "Learn from corrections": when the user fixes a cleaned entry, the words
/// they introduced that look like names or technical terms are offered for the
/// vocabulary list.
library;

final _word = RegExp(r'[\p{L}\p{N}](?:[\p{L}\p{N}._’\x27-]*[\p{L}\p{N}])?', unicode: true);
final _possessive = RegExp(r'[’\x27]s$', caseSensitive: false);

/// New capitalised words and technical tokens in [corrected] that were not in
/// [original], in order of appearance, without duplicates (case-insensitive).
///
/// Suggested: a capitalised word that is not just the start of a sentence
/// (Kubernetes, Neil), a token with inner capitals (GitHub, iOS, NASA), a
/// token mixing letters and digits (gpt4), and a token with an inner `.` or
/// `_` (package.json, snake_case). Plain lowercase words and ordinary
/// sentence-initial capitals are not.
List<String> suggestVocabulary(String original, String corrected, {int max = 8}) {
  final known = {for (final m in _word.allMatches(original)) _strip(m[0]!)};
  final seen = <String>{};
  final out = <String>[];
  for (final m in _word.allMatches(corrected)) {
    final token = _strip(m[0]!);
    if (token.length < 2 || known.contains(token)) continue;
    if (!_looksSpecial(token, atSentenceStart: _atSentenceStart(corrected, m.start))) continue;
    if (!seen.add(token.toLowerCase())) continue;
    out.add(token);
    if (out.length >= max) break;
  }
  return out;
}

String _strip(String s) => s.replaceFirst(_possessive, '');

bool _looksSpecial(String t, {required bool atSentenceStart}) {
  final letters = t.runes.where((r) => _isLetter(String.fromCharCode(r))).length;
  if (letters == 0) return false;
  final hasDigit = RegExp(r'\p{N}', unicode: true).hasMatch(t);
  if (hasDigit && letters > 0 && RegExp(r'\p{L}', unicode: true).hasMatch(t)) return true;
  if (RegExp(r'[._]').hasMatch(t) && letters >= 2) return true;
  final first = t.substring(0, t.offsetOfFirstRuneEnd());
  final rest = t.substring(first.length);
  if (rest != rest.toLowerCase()) return true; // inner capitals
  final capitalised = first != first.toLowerCase();
  return capitalised && !atSentenceStart;
}

bool _isLetter(String ch) => RegExp(r'\p{L}', unicode: true).hasMatch(ch);

bool _atSentenceStart(String text, int index) {
  for (var i = index - 1; i >= 0; i--) {
    final c = text[i];
    if (c == ' ' || c == '\t' || c == '"' || c == '“' || c == '(' || c == '-' || c == '*') continue;
    return c == '.' || c == '!' || c == '?' || c == '\n' || c == ':';
  }
  return true;
}

extension on String {
  /// Offset just after the first code point.
  int offsetOfFirstRuneEnd() => String.fromCharCode(runes.first).length;
}
