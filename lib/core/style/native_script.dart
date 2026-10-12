// SPDX-License-Identifier: GPL-3.0-or-later

import 'languages.dart';

/// A safety net for the "never romanize" rule. Models usually write a
/// Japanese or Chinese word inside English speech in its own script, but on
/// quiet or noisy audio they often fall back to romaji or pinyin
/// ("Sayonara"). For speakers who use that language, common words that only
/// exist in that language are rewritten here.
///
/// The lists are deliberately short: only phrases with no English meaning
/// (so "mama" or "nani" stay as they are; the model decides those).
abstract final class NativeScript {
  static const Map<String, String> japanese = {
    'arigatou gozaimasu': 'ありがとうございます',
    'arigato gozaimasu': 'ありがとうございます',
    'ohayou gozaimasu': 'おはようございます',
    'ohayo gozaimasu': 'おはようございます',
    'gomen nasai': 'ごめんなさい',
    'gomennasai': 'ごめんなさい',
    'sayonara': 'さようなら',
    'sayounara': 'さようなら',
    'arigatou': 'ありがとう',
    'arigato': 'ありがとう',
    'konnichiwa': 'こんにちは',
    'konbanwa': 'こんばんは',
    'ohayou': 'おはよう',
    'oyasumi': 'おやすみ',
    'oyasuminasai': 'おやすみなさい',
    'kawaii': 'かわいい',
    'sugoi': 'すごい',
    'itadakimasu': 'いただきます',
    'gochisousama': 'ごちそうさま',
    'otsukaresama': 'お疲れ様',
    'yoroshiku': 'よろしく',
    'daijoubu': '大丈夫',
    'sumimasen': 'すみません',
    'ganbatte': '頑張って',
    'yatta': 'やった',
  };

  static const Map<String, String> chinese = {
    'ni hao': '你好',
    'nihao': '你好',
    'xie xie': '谢谢',
    'xiexie': '谢谢',
    'zai jian': '再见',
    'zaijian': '再见',
    'mei guan xi': '没关系',
    'bu ke qi': '不客气',
    'dui bu qi': '对不起',
    'jia you': '加油',
  };

  static final Map<String, RegExp> _patterns = {};

  /// [text] with known romanized words rewritten for the [languages] the
  /// speaker uses; no languages selected means any language. Unchanged when
  /// other languages are selected but not Japanese or Chinese.
  static String apply(String text, Iterable<String> languages) {
    final codes = Languages.normaliseList(languages);
    var out = text;
    if (codes.isEmpty || codes.contains('ja')) out = _replace(out, japanese);
    if (codes.isEmpty || codes.contains('zh')) out = _replace(out, chinese);
    return out;
  }

  static String _replace(String text, Map<String, String> table) {
    var out = text;
    for (final e in table.entries) {
      final re = _patterns.putIfAbsent(
        e.key,
        () => RegExp(
          r'(?<![\p{L}\p{N}])' + e.key.split(' ').map(RegExp.escape).join(r'[\s-]+') + r'(?![\p{L}\p{N}])',
          caseSensitive: false,
          unicode: true,
        ),
      );
      out = out.replaceAll(re, e.value);
    }
    return out;
  }
}
