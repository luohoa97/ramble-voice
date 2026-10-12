// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'contact_names.dart';
import 'languages.dart';
import 'snippets.dart';

enum StylePreset {
  casual(
    'Casual',
    'Relaxed and conversational, with normal capitalization and punctuation. Contractions are fine',
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
  );

  const StylePreset(this.label, this.instruction);
  final String label;
  final String instruction;
}

/// The user's personal style, injected into every cleanup request.
class StyleProfile {
  const StyleProfile({
    this.preset = StylePreset.casual,
    this.customInstructions = '',
    this.vocabulary = const [],
    this.languages = const [],
    this.snippets = const [],
    this.contactNames = const [],
  });

  final StylePreset preset;
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
    return custom.isEmpty ? preset.instruction : '${preset.instruction}. $custom';
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
    String? customInstructions,
    List<String>? vocabulary,
    List<String>? languages,
    List<Snippet>? snippets,
    List<String>? contactNames,
  }) =>
      StyleProfile(
        preset: preset ?? this.preset,
        customInstructions: customInstructions ?? this.customInstructions,
        vocabulary: vocabulary ?? this.vocabulary,
        languages: languages ?? this.languages,
        snippets: snippets ?? this.snippets,
        contactNames: contactNames ?? this.contactNames,
      );

  Map<String, Object?> toJson() => {
        'preset': preset.name,
        'custom': customInstructions,
        'vocabulary': vocabulary,
      };

  factory StyleProfile.fromJson(Map<String, Object?> json) => StyleProfile(
        preset: StylePreset.values.asNameMap()[json['preset']] ?? StylePreset.casual,
        customInstructions: json['custom'] as String? ?? '',
        vocabulary: (json['vocabulary'] as List?)?.whereType<String>().toList() ?? const [],
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
