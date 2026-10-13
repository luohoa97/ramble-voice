// SPDX-License-Identifier: GPL-3.0-or-later

/// Spoken shortcuts: say a trigger phrase, get its expansion written.
library;

/// One shortcut. [trigger] is what the speaker says ("my email"), [expansion]
/// is what gets written ("x@y.com").
class Snippet {
  const Snippet({required this.trigger, required this.expansion});

  final String trigger;
  final String expansion;

  /// Longest trigger or expansion accepted into a prompt.
  static const maxLength = 500;

  Map<String, Object?> toJson() => {'trigger': trigger, 'expansion': expansion};

  factory Snippet.fromJson(Map<String, Object?> j) => Snippet(
    trigger: j['trigger'] as String? ?? '',
    expansion: j['expansion'] as String? ?? '',
  );

  Snippet copyWith({String? trigger, String? expansion}) => Snippet(
    trigger: trigger ?? this.trigger,
    expansion: expansion ?? this.expansion,
  );

  /// A snippet with an empty side does nothing.
  bool get isUsable => trigger.trim().isNotEmpty && expansion.trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is Snippet &&
      other.trigger == trigger &&
      other.expansion == expansion;

  @override
  int get hashCode => Object.hash(trigger, expansion);

  @override
  String toString() => 'Snippet($trigger -> $expansion)';
}

/// Usable snippets, deduplicated by trigger (case-insensitive, first wins).
List<Snippet> normaliseSnippets(Iterable<Snippet> snippets) {
  final seen = <String>{};
  return [
    for (final s in snippets)
      if (s.isUsable && seen.add(s.trigger.trim().toLowerCase()))
        Snippet(trigger: s.trigger.trim(), expansion: s.expansion.trim()),
  ];
}

/// The prompt sentence for [snippets], or an empty string when there are none.
///
/// Both sides are put on one line and stripped of characters that could fake
/// prompt structure (quotes, braces, angle brackets, backticks), the same way
/// vocabulary is. Newlines in an expansion are lost; a snippet is one line.
String describeSnippetList(Iterable<Snippet> snippets) {
  final pairs = [
    for (final s in normaliseSnippets(snippets))
      if (_clean(s.trigger).isNotEmpty && _clean(s.expansion).isNotEmpty)
        '"${_clean(s.trigger)}" → "${_clean(s.expansion)}"',
  ];
  if (pairs.isEmpty) return '';
  return 'When the speaker says one of these shortcut phrases as a standalone item, '
      'write the expansion instead: ${pairs.join('; ')}.';
}

String _clean(String s) {
  var t = s
      .replaceAll(RegExp(r'[\r\n]+'), ' ')
      .replaceAll(RegExp(r'[{}<>`"“”]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.length > Snippet.maxLength)
    t = t.substring(0, Snippet.maxLength).trim();
  return t;
}
