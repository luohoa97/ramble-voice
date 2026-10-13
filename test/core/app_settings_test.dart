// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/models/model_catalog.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';
import 'package:ramble_voice/core/style/style_profile.dart';

import '../fakes/temp_dirs.dart';

void main() {
  group('AppSettings', () {
    test('defaults', () {
      const s = AppSettings();
      expect(s.engine, EngineKind.onDevice);
      expect(s.gemmaVariantId, 'gemma-4-e4b');
      expect(s.geminiModel, isNull);
      expect(s.fallbackToOnDevice, isTrue);
      expect(s.onboarded, isFalse);
      expect(s.maxSessionMinutes, 10);
      expect(s.maxSession, const Duration(minutes: 10));
      expect(s.haptics, isTrue);
      expect(s.typeIntoFocusedApp, isTrue);
      expect(s.modelLicenseAccepted, isFalse);
      expect(s.gemmaVariant, ModelCatalog.e4b);
      expect(
        AppSettings.fromJson(const {}).toJson(),
        const AppSettings().toJson(),
      );
    });

    test('json round trip of non-default values', () {
      const s = AppSettings(
        engine: EngineKind.gemini,
        gemmaVariantId: 'gemma-4-e2b',
        geminiModel: 'gemini-3.5-flash-lite',
        fallbackToOnDevice: false,
        style: StyleProfile(
          preset: StylePreset.notes,
          customInstructions: 'x',
          vocabulary: ['Ramble'],
        ),
        onboarded: true,
        maxSessionMinutes: 25,
        haptics: false,
        typeIntoFocusedApp: false,
        modelLicenseAccepted: true,
      );
      final back = AppSettings.fromJson(
        (jsonDecode(jsonEncode(s.toJson())) as Map).cast<String, Object?>(),
      );
      expect(back.toJson(), s.toJson());
      expect(back.engine, EngineKind.gemini);
      expect(back.gemmaVariant, ModelCatalog.e2b);
      expect(back.style.vocabulary, ['Ramble']);
    });

    test('maxSessionMinutes is clamped to 1..60', () {
      expect(
        AppSettings.fromJson({'maxSessionMinutes': 0}).maxSessionMinutes,
        1,
      );
      expect(
        AppSettings.fromJson({'maxSessionMinutes': -5}).maxSessionMinutes,
        1,
      );
      expect(
        AppSettings.fromJson({'maxSessionMinutes': 999}).maxSessionMinutes,
        60,
      );
      expect(
        AppSettings.fromJson({'maxSessionMinutes': 12.7}).maxSessionMinutes,
        12,
      );
    });

    test('unknown enum values fall back to defaults', () {
      final s = AppSettings.fromJson({
        'engine': 'quantum',
        'style': 'oops',
        'maxSessionMinutes': null,
      });
      expect(s.engine, EngineKind.onDevice);
      expect(s.style, const StyleProfile());
      expect(s.maxSessionMinutes, 10);
    });

    test('an unknown gemma variant id resolves to the default variant', () {
      expect(
        const AppSettings(gemmaVariantId: 'gone').gemmaVariant,
        ModelCatalog.defaultVariant,
      );
    });

    test('copyWith changes only what is given, and can clear geminiModel', () {
      const s = AppSettings(geminiModel: 'm', onboarded: true);
      expect(s.copyWith(haptics: false).geminiModel, 'm');
      expect(s.copyWith(haptics: false).onboarded, isTrue);
      expect(s.copyWith(geminiModel: () => null).geminiModel, isNull);
      expect(s.copyWith(geminiModel: () => 'n').geminiModel, 'n');
      expect(s.copyWith(engine: EngineKind.gemini).engine, EngineKind.gemini);
    });
  });

  group('SettingsStore', () {
    late File file;
    setUp(
      () async =>
          file = File('${(await makeTempDir()).path}/nested/settings.json'),
    );

    test('missing file loads defaults', () async {
      expect(
        (await SettingsStore(
          file,
          deviceLanguages: () => const [],
        ).load()).toJson(),
        const AppSettings().toJson(),
      );
    });

    test('save then load round trips and creates parent directories', () async {
      final store = SettingsStore(file, deviceLanguages: () => const []);
      const s = AppSettings(
        engine: EngineKind.gemini,
        onboarded: true,
        maxSessionMinutes: 3,
      );
      await store.save(s);
      expect(
        (await SettingsStore(
          file,
          deviceLanguages: () => const [],
        ).load()).toJson(),
        s.toJson(),
      );
    });

    test('save leaves no temp file behind and overwrites cleanly', () async {
      final store = SettingsStore(file, deviceLanguages: () => const []);
      await store.save(const AppSettings(onboarded: true));
      await store.save(const AppSettings(onboarded: false, haptics: false));
      expect(await File('${file.path}.tmp').exists(), isFalse);
      final loaded = await store.load();
      expect(loaded.onboarded, isFalse);
      expect(loaded.haptics, isFalse);
    });

    test(
      'a stale temp file from a crash does not break save or load',
      () async {
        await file.parent.create(recursive: true);
        await File('${file.path}.tmp').writeAsString('{ half written');
        final store = SettingsStore(file, deviceLanguages: () => const []);
        expect((await store.load()).toJson(), const AppSettings().toJson());
        await store.save(const AppSettings(onboarded: true));
        expect((await store.load()).onboarded, isTrue);
      },
    );

    test(
      'a wrongly typed field makes the whole file load as defaults',
      () async {
        await file.parent.create(recursive: true);
        await file.writeAsString(
          jsonEncode({'onboarded': true, 'gemmaVariant': 7}),
        );
        expect(
          (await SettingsStore(
            file,
            deviceLanguages: () => const [],
          ).load()).onboarded,
          isFalse,
        );
      },
    );

    test('corrupt files load defaults', () async {
      await file.parent.create(recursive: true);
      for (final junk in ['', '{not json', '[]', '"text"', 'null']) {
        await file.writeAsString(junk);
        expect(
          (await SettingsStore(
            file,
            deviceLanguages: () => const [],
          ).load()).toJson(),
          const AppSettings().toJson(),
          reason: junk,
        );
      }
    });
  });

  test('KeySource has the documented values', () {
    expect(KeySource.values.map((e) => e.name), [
      'none',
      'secureStorage',
      'environment',
    ]);
  });
}
