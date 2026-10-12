// SPDX-License-Identifier: GPL-3.0-or-later

/// Dictation languages offered in Settings.
library;

class Language {
  const Language(this.code, this.name);

  /// BCP-47 code, or [auto].
  final String code;

  /// English display name, also what the prompt uses.
  final String name;
}

abstract final class Languages {
  /// Detect the spoken language (and keep mixed languages as spoken).
  static const auto = 'auto';

  static const autoLanguage = Language(auto, 'Detect automatically');

  static const List<Language> all = [
    Language('en', 'English'),
    Language('es', 'Spanish'),
    Language('fr', 'French'),
    Language('de', 'German'),
    Language('it', 'Italian'),
    Language('pt', 'Portuguese'),
    Language('nl', 'Dutch'),
    Language('sv', 'Swedish'),
    Language('da', 'Danish'),
    Language('no', 'Norwegian'),
    Language('fi', 'Finnish'),
    Language('pl', 'Polish'),
    Language('cs', 'Czech'),
    Language('sk', 'Slovak'),
    Language('hu', 'Hungarian'),
    Language('ro', 'Romanian'),
    Language('bg', 'Bulgarian'),
    Language('el', 'Greek'),
    Language('tr', 'Turkish'),
    Language('ru', 'Russian'),
    Language('uk', 'Ukrainian'),
    Language('he', 'Hebrew'),
    Language('ar', 'Arabic'),
    Language('fa', 'Persian'),
    Language('hi', 'Hindi'),
    Language('bn', 'Bengali'),
    Language('ur', 'Urdu'),
    Language('ta', 'Tamil'),
    Language('te', 'Telugu'),
    Language('mr', 'Marathi'),
    Language('th', 'Thai'),
    Language('vi', 'Vietnamese'),
    Language('id', 'Indonesian'),
    Language('ms', 'Malay'),
    Language('fil', 'Filipino'),
    Language('zh', 'Chinese (Mandarin)'),
    Language('yue', 'Cantonese'),
    Language('ja', 'Japanese'),
    Language('ko', 'Korean'),
    Language('sw', 'Swahili'),
    Language('af', 'Afrikaans'),
    Language('ca', 'Catalan'),
    Language('hr', 'Croatian'),
  ];

  /// The picker list: automatic first.
  static List<Language> get choices => [autoLanguage, ...all];

  /// The language for [code], matching the region-less part of codes like
  /// `pt-BR`. Null for blank or unknown codes.
  static Language? byCode(String? code) {
    final c = code?.trim().toLowerCase();
    if (c == null || c.isEmpty || c == auto) return null;
    for (final l in all) {
      if (l.code == c) return l;
    }
    final base = c.split(RegExp(r'[-_]')).first;
    for (final l in all) {
      if (l.code == base) return l;
    }
    return null;
  }

  /// Display name for [code], or the code itself when unknown.
  static String displayName(String code) => byCode(code)?.name ?? code;

  /// Known codes from [codes] as listed in [all], without duplicates, in order.
  /// An empty result means "detect any language".
  static List<String> normaliseList(Iterable<String?> codes) {
    final out = <String>[];
    for (final c in codes) {
      final l = byCode(c);
      if (l != null && !out.contains(l.code)) out.add(l.code);
    }
    return out;
  }

  /// The prompt sentence for [codes]. No known language means "detect any".
  /// With [allowTranslation] (edit mode) a spoken instruction may ask for a
  /// translation.
  static String describe(Iterable<String> codes, {bool allowTranslation = false}) {
    final names = [for (final l in normaliseList(codes)) byCode(l)!.name];
    // The user's languages are a hint, never a limit: other languages that
    // are actually spoken are still written as themselves.
    final subject = names.isEmpty
        ? ''
        : names.length == 1
            ? 'The speaker usually speaks ${names.single}. '
            : 'The speaker usually speaks ${names.join(', ')}. ';
    const script = 'Write each language in its own writing system, never romanized: Japanese in kana and kanji '
        '(for example ありがとうございます), Chinese in Chinese characters, Korean in Hangul, Russian in '
        'Cyrillic, Arabic in Arabic script, and so on. A word borrowed into the surrounding sentence\'s language '
        '(sushi, karaoke, kimchi in an English sentence) stays as that language writes it. ';
    final rule = allowTranslation
        ? 'Keep every word in the language it is written in; never switch a word into another language '
            'unless the spoken instruction asks for a translation.'
        : 'Write every word in the language it was spoken in; never translate.';
    return '$subject$script$rule';
  }

}
