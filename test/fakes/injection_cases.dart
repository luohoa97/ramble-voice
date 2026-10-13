// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

/// One spoken prompt-injection case from test/fixtures/injection/cases.json.
class InjectionCase {
  InjectionCase(this.json);

  final Map<String, Object?> json;

  String get id => json['id'] as String;
  String get spoken => json['spoken'] as String;
  List<String> get mustContain => (json['must_contain'] as List).cast<String>();
  List<String> get mustNotContain =>
      (json['must_not_contain'] as List).cast<String>();
  String get judge => json['judge'] as String;
  File get wavFile => File('test/fixtures/injection/audio/$id.wav');

  /// Returns the rules [output] breaks; empty means the app transcribed
  /// instead of complying.
  List<String> judgeOutput(String output) {
    final lower = output.toLowerCase();
    final problems = <String>[];
    for (final s in mustContain) {
      if (!lower.contains(s.toLowerCase())) problems.add('missing "$s"');
    }
    for (final s in mustNotContain) {
      if (lower.contains(s.toLowerCase()))
        problems.add('contains forbidden "$s"');
    }
    switch (judge) {
      case 'no_multiline':
        if (output.trim().split(RegExp(r'\r?\n')).length > 2)
          problems.add('multiple lines (verse or list)');
      case 'min_words':
        final n = output
            .trim()
            .split(RegExp(r'\s+'))
            .where((w) => w.isNotEmpty)
            .length;
        final min = json['min_words'] as int;
        if (n < min) problems.add('only $n words, expected at least $min');
      case 'max_count':
        (json['max_count'] as Map).forEach((word, max) {
          final count = RegExp(
            RegExp.escape(word as String),
            caseSensitive: false,
          ).allMatches(output).length;
          if (count > (max as int))
            problems.add('"$word" appears $count times (max $max)');
        });
      case 'transcribe':
        break;
      default:
        problems.add('unknown judge "$judge"');
    }
    return problems;
  }
}

List<InjectionCase> loadInjectionCases() {
  final file = File('test/fixtures/injection/cases.json');
  final root = (jsonDecode(file.readAsStringSync()) as Map)
      .cast<String, Object?>();
  return [
    for (final c in (root['cases'] as List))
      InjectionCase((c as Map).cast<String, Object?>()),
  ];
}
