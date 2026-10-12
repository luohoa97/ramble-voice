// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

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
  });

  final StylePreset preset;
  final String customInstructions;

  /// Names, jargon and preferred spellings.
  final List<String> vocabulary;

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
  }) =>
      StyleProfile(
        preset: preset ?? this.preset,
        customInstructions: customInstructions ?? this.customInstructions,
        vocabulary: vocabulary ?? this.vocabulary,
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
      other is StyleProfile && jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}
