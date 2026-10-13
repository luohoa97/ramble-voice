// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'contact_names.dart';
import 'languages.dart';
import 'snippets.dart';

enum StylePreset {
  casual(
    'Casual',
    'Relaxed and conversational, with normal capitalization and punctuation. Contractions are fine. Adapt the '
    'shape to the length: a quick remark stays one or two plain sentences; a long ramble or speech becomes '
    'well-organized paragraphs, one per idea, with a list where the speaker lists things, still in their own '
    'relaxed voice',
  ),
  professional(
    'Professional',
    'Clear, polite and complete sentences. No slang',
  ),
  texting(
    'Texting',
    'Short and quick like a chat message. Casual capitalization and minimal punctuation are fine',
  ),
  notes(
    'Notes',
    'Concise notes. Use short lines or bullet points ("- ") when the speaker lists things',
  ),
  markdown(
    'Markdown',
    'Clean, well-structured Markdown for notes, documentation and AI chats. Use "# " for a title and "## " '
    'for sections only when the dictation has several distinct parts, "- " bullets and "1. " numbered lists '
    'for lists and steps, "- [ ] " for tasks and to-dos, **bold** only for terms the speaker stresses, single '
    'backticks around commands, file names, code and identifiers, a fenced code block with its language for '
    'multi-line code, "> " for quotations, and a GitHub-flavored Markdown table with a header row when the '
    'speaker compares several items or gives rows of data. Leave a blank line between blocks. Never wrap the '
    'whole text in a code block. Short dictation stays a plain sentence',
  );

  const StylePreset(this.label, this.instruction);
  final String label;
  final String instruction;
}

/// How much the cleanup rewrites.
enum Polish {
  /// Remove fillers and false starts, fix punctuation; keep the wording.
  light('Light', 'Removes um and uh, fixes punctuation, keeps your wording.'),

  /// Also fix grammar and awkward phrasing so every sentence reads well.
  full('Full', 'Also fixes grammar and awkward phrasing.');

  const Polish(this.label, this.description);
  final String label;
  final String description;
}

/// The user's personal style, injected into every cleanup request.
class StyleProfile {
  const StyleProfile({
    this.preset = StylePreset.casual,
    this.polish = Polish.light,
    this.customInstructions = '',
    this.vocabulary = const [],
    this.languages = const [],
    this.snippets = const [],
    this.contactNames = const [],
    this.textSpeak = false,
  });

  final StylePreset preset;

  /// Texting tone only: write common chat abbreviations (ngl, tbh, idk, gng).
  final bool textSpeak;
  final Polish polish;
  final String customInstructions;

  /// Names, jargon and preferred spellings.
  final List<String> vocabulary;

  /// BCP-47 codes of the languages the speaker uses; empty means any. Composed
  /// from `AppSettings.languages` per request; not part of [toJson].
  final List<String> languages;

  /// Address-book names to spell correctly, when the user opted in. Composed
  /// per request; not part of [toJson].
  final List<String> contactNames;

  /// Spoken shortcuts. Composed from `AppSettings.snippets` per request; not
  /// part of [toJson].
  final List<Snippet> snippets;

  /// The `{style}` text for the cleanup prompt.
  String describe() {
    final custom = customInstructions.trim();
    final base = preset == StylePreset.texting && textSpeak
        ? '${preset.instruction}. Write the usual chat abbreviations and slang spellings where people type them '
            '(not gonna lie becomes ngl, to be honest tbh, I don\'t know idk, gang gng, be right back brb, '
            'oh my god omg, laughing out loud lol), lowercase'
        : preset.instruction;
    return custom.isEmpty ? base : '$base. $custom';
  }

  /// The `{vocab}` text for the cleanup prompt.
  String describeVocabulary() {
    final words = normalisedVocabulary;
    return words.isEmpty ? '(none)' : words.join(', ');
  }

  /// The prompt sentence about the spoken language.
  String describeLanguage() => Languages.describe(languages);

  /// Same, for edit mode, where an instruction may ask for a translation.
  String describeLanguageForEdit() => Languages.describe(languages, allowTranslation: true);

  /// Whether a specific set of languages is configured.
  bool get hasLanguages => Languages.normaliseList(languages).isNotEmpty;

  /// The prompt sentence about contact names, or '' when there are none.
  String describeContacts() => describeContactNames(contactNames);

  /// The prompt sentence about spoken shortcuts, or '' when there are none.
  String describeSnippets() => describeSnippetList(snippets);

  List<String> get normalisedVocabulary {
    final seen = <String>{};
    return [
      for (final w in vocabulary.map((w) => w.trim()))
        if (w.isNotEmpty && seen.add(w.toLowerCase())) w,
    ];
  }

  StyleProfile copyWith({
    StylePreset? preset,
    Polish? polish,
    String? customInstructions,
    List<String>? vocabulary,
    List<String>? languages,
    List<Snippet>? snippets,
    List<String>? contactNames,
    bool? textSpeak,
  }) =>
      StyleProfile(
        preset: preset ?? this.preset,
        polish: polish ?? this.polish,
        customInstructions: customInstructions ?? this.customInstructions,
        vocabulary: vocabulary ?? this.vocabulary,
        languages: languages ?? this.languages,
        snippets: snippets ?? this.snippets,
        contactNames: contactNames ?? this.contactNames,
        textSpeak: textSpeak ?? this.textSpeak,
      );

  Map<String, Object?> toJson() => {
        'preset': preset.name,
        'polish': polish.name,
        'custom': customInstructions,
        'vocabulary': vocabulary,
        'textSpeak': textSpeak,
      };

  factory StyleProfile.fromJson(Map<String, Object?> json) => StyleProfile(
        preset: StylePreset.values.asNameMap()[json['preset']] ?? StylePreset.casual,
        polish: Polish.values.asNameMap()[json['polish']] ?? Polish.light,
        customInstructions: json['custom'] as String? ?? '',
        vocabulary: (json['vocabulary'] as List?)?.whereType<String>().toList() ?? const [],
        textSpeak: json['textSpeak'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is StyleProfile &&
      jsonEncode(toJson()) == jsonEncode(other.toJson()) &&
      _sameStrings(languages, other.languages) &&
      _sameStrings(contactNames, other.contactNames) &&
      _sameSnippets(snippets, other.snippets);

  @override
  int get hashCode => Object.hash(jsonEncode(toJson()), Object.hashAll(languages), Object.hashAll(contactNames), Object.hashAll(snippets));

  static bool _sameStrings(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameSnippets(List<Snippet> a, List<Snippet> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
