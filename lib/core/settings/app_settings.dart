// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import '../cleanup/cleanup_engine.dart';
import '../models/model_catalog.dart';
import '../style/device_languages.dart';
import '../style/languages.dart';
import '../style/snippets.dart';
import '../style/style_profile.dart';

/// Size of the Android floating mic bubble.
enum BubbleSize { small, medium }

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
    this.autoSwitchBack = true,
    this.hotkeyTrigger = 'CTRL+ALT+space',
    this.languages = const [],
    this.useContactNames = false,
    this.snippets = const [],
    this.appStyles = const {},
    this.completedSetup = const {},
    this.bubbleBlockedApps = const [],
    this.bubbleSize = BubbleSize.medium,
    this.bubbleAutoRestore = false,
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

  /// Android keyboard: return to the previous keyboard (e.g. Gboard) after
  /// inserting dictated text.
  final bool autoSwitchBack;

  /// Linux: preferred global shortcut (portal trigger syntax, e.g.
  /// `CTRL+ALT+space`, or `Menu` when Caps Lock is mapped to Menu).
  final String hotkeyTrigger;

  /// BCP-47 codes from [Languages.all] the speaker uses. Empty means "detect
  /// any language". A fresh install starts with the device's language(s).
  final List<String> languages;

  /// Spell address-book names correctly. Off by default: in Gemini mode the
  /// names are sent to Google with each request.
  final bool useContactNames;

  /// Spoken shortcuts expanded during cleanup.
  final List<Snippet> snippets;

  /// [style] plus the language and snippets: what the engines get.
  StyleProfile get effectiveStyle => style.copyWith(languages: languages, snippets: snippets);

  /// Android floating mic: package names of apps where the bubble never shows.
  final List<String> bubbleBlockedApps;
  final BubbleSize bubbleSize;

  /// Opt-in: turn the floating mic back on if the system switched it off.
  /// Needs WRITE_SECURE_SETTINGS granted over adb.
  final bool bubbleAutoRestore;

  /// Keyboard: tone overrides per app, keyed by Android package name. Apps
  /// without an entry use the built-in defaults, then [StyleProfile.preset].
  final Map<String, StylePreset> appStyles;

  /// Setup guide steps the user has finished, by id. `dismissed` hides the
  /// "Finish setup" banner.
  final Set<String> completedSetup;

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
    bool? autoSwitchBack,
    String? hotkeyTrigger,
    List<String>? languages,
    bool? useContactNames,
    List<Snippet>? snippets,
    Map<String, StylePreset>? appStyles,
    Set<String>? completedSetup,
    List<String>? bubbleBlockedApps,
    BubbleSize? bubbleSize,
    bool? bubbleAutoRestore,
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
        autoSwitchBack: autoSwitchBack ?? this.autoSwitchBack,
        hotkeyTrigger: hotkeyTrigger ?? this.hotkeyTrigger,
        languages: languages ?? this.languages,
        useContactNames: useContactNames ?? this.useContactNames,
        snippets: snippets ?? this.snippets,
        appStyles: appStyles ?? this.appStyles,
        completedSetup: completedSetup ?? this.completedSetup,
        bubbleBlockedApps: bubbleBlockedApps ?? this.bubbleBlockedApps,
        bubbleSize: bubbleSize ?? this.bubbleSize,
        bubbleAutoRestore: bubbleAutoRestore ?? this.bubbleAutoRestore,
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
        'autoSwitchBack': autoSwitchBack,
        'hotkeyTrigger': hotkeyTrigger,
        'languages': languages,
        'useContactNames': useContactNames,
        'snippets': [for (final s in snippets) s.toJson()],
        'appStyles': {for (final e in appStyles.entries) e.key: e.value.name},
        'completedSetup': completedSetup.toList()..sort(),
        'bubbleBlockedApps': bubbleBlockedApps,
        'bubbleSize': bubbleSize.name,
        'bubbleAutoRestore': bubbleAutoRestore,
      };

  /// [deviceLanguages] is used when the file has no language choice yet, or
  /// still has the old automatic setting.
  factory AppSettings.fromJson(Map<String, Object?> j, {List<String> deviceLanguages = const []}) => AppSettings(
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
        autoSwitchBack: j['autoSwitchBack'] as bool? ?? true,
        hotkeyTrigger: j['hotkeyTrigger'] as String? ?? 'CTRL+ALT+space',
        languages: _languagesFromJson(j, deviceLanguages),
        useContactNames: j['useContactNames'] as bool? ?? false,
        snippets: [
          for (final e in j['snippets'] is List ? j['snippets'] as List : const [])
            if (e is Map) Snippet.fromJson(e.cast<String, Object?>()),
        ],
        appStyles: _appStylesFromJson(j['appStyles']),
        completedSetup: {...((j['completedSetup'] as List?)?.whereType<String>() ?? const <String>[])},
        bubbleBlockedApps: [
          if (j['bubbleBlockedApps'] case final List<Object?> l) ...l.whereType<String>(),
        ],
        bubbleSize: BubbleSize.values.asNameMap()[j['bubbleSize']] ?? BubbleSize.medium,
        bubbleAutoRestore: j['bubbleAutoRestore'] as bool? ?? false,
      );
}

List<String> _languagesFromJson(Map<String, Object?> j, List<String> device) {
  final list = j['languages'];
  if (list is List) return Languages.normaliseList(list.whereType<String>());
  // Migrate the old single `language`: a fixed code stays, "auto" and nothing
  // become the device's language(s).
  final raw = j['language'];
  final old = Languages.byCode(raw is String ? raw : null);
  return old == null ? Languages.normaliseList(device) : [old.code];
}

Map<String, StylePreset> _appStylesFromJson(Object? raw) {
  if (raw is! Map) return const {};
  final presets = StylePreset.values.asNameMap();
  return {
    for (final e in raw.entries)
      if (e.key is String && presets[e.value] != null) e.key as String: presets[e.value]!,
  };
}

/// Stores [AppSettings] as JSON. Writes go through a temp file and rename so
/// a crash never leaves a half-written file.
class SettingsStore {
  SettingsStore(this.file, {this.deviceLanguages = detectDeviceLanguages});
  final File file;

  /// The languages a fresh install starts with.
  final List<String> Function() deviceLanguages;

  Future<AppSettings> load() async {
    try {
      if (!await file.exists()) return AppSettings(languages: deviceLanguages());
      return AppSettings.fromJson(
        (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>(),
        deviceLanguages: deviceLanguages(),
      );
    } catch (_) {
      return AppSettings(languages: deviceLanguages());
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
