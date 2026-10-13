// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';
import 'package:ramble_voice/core/style/app_styles.dart';
import 'package:ramble_voice/core/style/style_profile.dart';

void main() {
  group('built-in defaults', () {
    test('mail apps are professional', () {
      expect(builtInStyleFor('com.google.android.gm'), StylePreset.professional);
      expect(builtInStyleFor('com.microsoft.office.outlook'), StylePreset.professional);
      expect(builtInStyleFor('ch.protonmail.android'), StylePreset.professional);
      expect(builtInStyleFor('com.fastmail.app'), StylePreset.professional);
    });

    test('chat apps are texting', () {
      for (final p in [
        'com.whatsapp',
        'com.whatsapp.w4b',
        'org.telegram.messenger',
        'org.thoughtcrime.securesms',
        'com.discord',
        'com.facebook.orca',
        'com.instagram.android',
        'com.snapchat.android',
        'com.google.android.apps.messaging',
        'com.Slack',
      ]) {
        expect(builtInStyleFor(p), StylePreset.texting, reason: p);
      }
    });

    test('note apps are notes', () {
      for (final p in [
        'com.google.android.keep',
        'com.notion.id',
        'com.evernote',
        'com.samsung.android.app.notes',
      ]) {
        expect(builtInStyleFor(p), StylePreset.notes, reason: p);
      }
    });

    test('Obsidian gets Markdown', () {
      expect(builtInStyleFor('md.obsidian'), StylePreset.markdown);
    });

    test('prefixes only match on a package boundary', () {
      expect(builtInStyleFor('com.google.android.gms'), isNull);
      expect(builtInStyleFor('com.whatsappfake'), isNull);
      expect(builtInStyleFor(null), isNull);
      expect(builtInStyleFor(''), isNull);
    });
  });

  group('styleFor', () {
    test('falls back to the global preset', () {
      expect(styleFor(null), StylePreset.casual);
      expect(styleFor('com.example.browser', global: StylePreset.professional), StylePreset.professional);
    });

    test('built-in beats global', () {
      expect(styleFor('com.whatsapp', global: StylePreset.professional), StylePreset.texting);
    });

    test('override beats built-in', () {
      expect(
        styleFor('com.whatsapp', overrides: {'com.whatsapp': StylePreset.notes}),
        StylePreset.notes,
      );
    });

    test('overrides are per package', () {
      final overrides = {'com.example.a': StylePreset.notes};
      expect(styleFor('com.example.a', overrides: overrides), StylePreset.notes);
      expect(styleFor('com.example.b', overrides: overrides), StylePreset.casual);
    });
  });

  group('AppSettings integration', () {
    test('resolves through settings and keeps vocabulary and instructions', () {
      const s = AppSettings(
        style: StyleProfile(preset: StylePreset.professional, customInstructions: 'No emoji', vocabulary: ['Ramble']),
        appStyles: {'com.example.notes': StylePreset.notes},
      );
      expect(s.styleForApp('com.example.notes'), StylePreset.notes);
      expect(s.styleForApp('com.whatsapp'), StylePreset.texting);
      expect(s.styleForApp(null), StylePreset.professional);
      final p = s.styleProfileFor('com.example.notes');
      expect(p.preset, StylePreset.notes);
      expect(p.customInstructions, 'No emoji');
      expect(p.vocabulary, ['Ramble']);
    });

    test('appStyles round-trips through json', () {
      const s = AppSettings(appStyles: {'com.a': StylePreset.texting, 'com.b': StylePreset.notes});
      final back = AppSettings.fromJson(s.toJson());
      expect(back.appStyles, s.appStyles);
      expect(back.toJson(), s.toJson());
    });

    test('unknown presets and bad entries are dropped on load', () {
      final s = AppSettings.fromJson({
        'appStyles': {'com.a': 'texting', 'com.b': 'shouting', 'com.c': 3},
      });
      expect(s.appStyles, {'com.a': StylePreset.texting});
      expect(AppSettings.fromJson({'appStyles': 'nope'}).appStyles, isEmpty);
      expect(AppSettings.fromJson(const {}).appStyles, isEmpty);
    });

    test('copyWith keeps and replaces appStyles', () {
      const s = AppSettings(appStyles: {'com.a': StylePreset.notes});
      expect(s.copyWith(haptics: false).appStyles, s.appStyles);
      expect(s.copyWith(appStyles: const {}).appStyles, isEmpty);
    });
  });
}
