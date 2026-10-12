// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import '../cleanup/cleanup_engine.dart';
import '../models/model_catalog.dart';
import '../style/style_profile.dart';

/// Non-secret preferences. The Gemini key lives in [SecretStore].
class AppSettings {
  const AppSettings({
    this.engine = EngineKind.onDevice,
    this.gemmaVariantId = 'gemma-4-e4b',
    this.geminiModel,
    this.fallbackToOnDevice = true,
    this.style = const StyleProfile(),
    this.onboarded = false,
    this.maxSessionMinutes = 10,
    this.haptics = true,
    this.typeIntoFocusedApp = true,
    this.modelLicenseAccepted = false,
  });

  final EngineKind engine;
  final String gemmaVariantId;

  /// User-picked Gemini model id within the newest Flash-Lite generation.
  /// Null means "newest stable".
  final String? geminiModel;

  /// In cloud mode, retry on-device when Gemini is rate limited or offline.
  final bool fallbackToOnDevice;
  final StyleProfile style;
  final bool onboarded;
  final int maxSessionMinutes;
  final bool haptics;

  /// Linux: insert into the focused app (otherwise clipboard only).
  final bool typeIntoFocusedApp;
  final bool modelLicenseAccepted;

  GemmaVariant get gemmaVariant => ModelCatalog.byId(gemmaVariantId) ?? ModelCatalog.defaultVariant;
  Duration get maxSession => Duration(minutes: maxSessionMinutes);

  AppSettings copyWith({
    EngineKind? engine,
    String? gemmaVariantId,
    String? Function()? geminiModel,
    bool? fallbackToOnDevice,
    StyleProfile? style,
    bool? onboarded,
    int? maxSessionMinutes,
    bool? haptics,
    bool? typeIntoFocusedApp,
    bool? modelLicenseAccepted,
  }) =>
      AppSettings(
        engine: engine ?? this.engine,
        gemmaVariantId: gemmaVariantId ?? this.gemmaVariantId,
        geminiModel: geminiModel == null ? this.geminiModel : geminiModel(),
        fallbackToOnDevice: fallbackToOnDevice ?? this.fallbackToOnDevice,
        style: style ?? this.style,
        onboarded: onboarded ?? this.onboarded,
        maxSessionMinutes: maxSessionMinutes ?? this.maxSessionMinutes,
        haptics: haptics ?? this.haptics,
        typeIntoFocusedApp: typeIntoFocusedApp ?? this.typeIntoFocusedApp,
        modelLicenseAccepted: modelLicenseAccepted ?? this.modelLicenseAccepted,
      );

  Map<String, Object?> toJson() => {
        'engine': engine.name,
        'gemmaVariant': gemmaVariantId,
        'geminiModel': geminiModel,
        'fallbackToOnDevice': fallbackToOnDevice,
        'style': style.toJson(),
        'onboarded': onboarded,
        'maxSessionMinutes': maxSessionMinutes,
        'haptics': haptics,
        'typeIntoFocusedApp': typeIntoFocusedApp,
        'modelLicenseAccepted': modelLicenseAccepted,
      };

  factory AppSettings.fromJson(Map<String, Object?> j) => AppSettings(
        engine: EngineKind.values.asNameMap()[j['engine']] ?? EngineKind.onDevice,
        gemmaVariantId: j['gemmaVariant'] as String? ?? 'gemma-4-e4b',
        geminiModel: j['geminiModel'] as String?,
        fallbackToOnDevice: j['fallbackToOnDevice'] as bool? ?? true,
        style: j['style'] is Map
            ? StyleProfile.fromJson((j['style'] as Map).cast<String, Object?>())
            : const StyleProfile(),
        onboarded: j['onboarded'] as bool? ?? false,
        maxSessionMinutes: (j['maxSessionMinutes'] as num?)?.toInt().clamp(1, 60) ?? 10,
        haptics: j['haptics'] as bool? ?? true,
        typeIntoFocusedApp: j['typeIntoFocusedApp'] as bool? ?? true,
        modelLicenseAccepted: j['modelLicenseAccepted'] as bool? ?? false,
      );
}

/// Stores [AppSettings] as JSON. Writes go through a temp file and rename so
/// a crash never leaves a half-written file.
class SettingsStore {
  SettingsStore(this.file);
  final File file;

  Future<AppSettings> load() async {
    try {
      if (!await file.exists()) return const AppSettings();
      return AppSettings.fromJson((jsonDecode(await file.readAsString()) as Map).cast<String, Object?>());
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings s) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()), flush: true);
    await tmp.rename(file.path);
  }
}

/// Secret storage for the Gemini API key. Android: Keystore-backed
/// flutter_secure_storage. Linux: the Secret Service (libsecret / GNOME
/// Keyring / KWallet) over D-Bus, with `GEMINI_API_KEY` taking precedence.
abstract interface class SecretStore {
  Future<String?> readGeminiKey();
  Future<void> writeGeminiKey(String key);
  Future<void> deleteGeminiKey();

  /// Where the key currently comes from, for the Settings screen.
  Future<KeySource> geminiKeySource();
}

enum KeySource { none, secureStorage, environment }
