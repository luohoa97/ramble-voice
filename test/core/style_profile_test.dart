// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/style/style_profile.dart';

void main() {
  test('json round trip', () {
    const p = StyleProfile(
      preset: StylePreset.notes,
      customInstructions: 'Use British spelling.',
      vocabulary: ['Kubernetes', 'Ramble'],
    );
    final back = StyleProfile.fromJson((jsonDecode(jsonEncode(p.toJson())) as Map).cast<String, Object?>());
    expect(back, p);
    expect(back.preset, StylePreset.notes);
    expect(back.vocabulary, ['Kubernetes', 'Ramble']);
  });

  test('fromJson tolerates missing and bad fields', () {
    final p = StyleProfile.fromJson({'preset': 'nope', 'vocabulary': ['a', 3, null]});
    expect(p.preset, StylePreset.casual);
    expect(p.customInstructions, '');
    expect(p.vocabulary, ['a']);
    expect(StyleProfile.fromJson(const {}), const StyleProfile());
  });

  test('every preset has a label and instruction', () {
    expect(StylePreset.values, hasLength(5));
    for (final p in StylePreset.values) {
      expect(p.label, isNotEmpty);
      expect(p.instruction, isNotEmpty);
    }
  });

  test('describe appends custom instructions', () {
    expect(const StyleProfile().describe(), StylePreset.casual.instruction);
    expect(
      const StyleProfile(preset: StylePreset.texting, customInstructions: ' Be brief. ').describe(),
      '${StylePreset.texting.instruction}. Be brief.',
    );
  });

  test('vocabulary is trimmed and deduplicated case-insensitively', () {
    const p = StyleProfile(vocabulary: [' Gemma ', 'gemma', 'GEMMA', '', 'Ramble']);
    expect(p.normalisedVocabulary, ['Gemma', 'Ramble']);
    expect(p.describeVocabulary(), 'Gemma, Ramble');
    expect(const StyleProfile().describeVocabulary(), '(none)');
  });

  test('copyWith and equality', () {
    const p = StyleProfile();
    final q = p.copyWith(preset: StylePreset.professional);
    expect(q.preset, StylePreset.professional);
    expect(q, isNot(p));
    expect(p.copyWith(), p);
    expect(p.copyWith().hashCode, p.hashCode);
  });
}
