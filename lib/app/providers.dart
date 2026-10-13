// SPDX-License-Identifier: GPL-3.0-or-later

/// Composition root. Platform-specific pieces are injected by overriding
/// [platformServicesProvider], [appPathsProvider] and [initialSettingsProvider]
/// in main.dart / main_ime.dart.
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/diagnostics/usage_log.dart';
import '../core/cleanup/cleanup_engine.dart';
import '../core/cleanup/cleanup_pipeline.dart';
import '../core/cleanup/gemini/gemini_client.dart';
import '../core/cleanup/gemini/gemini_engine.dart';
import '../core/cleanup/gemma/gemma_engine.dart';
import '../core/dictation/dictation_controller.dart';
import '../core/dictation/edit_controller.dart';
import '../core/dictation/recording_vault.dart';
import '../core/history/history_db.dart';
import '../core/models/model_catalog.dart';
import '../core/models/model_downloader.dart';
import '../core/models/model_downloads.dart';
import '../core/settings/app_settings.dart';
import '../core/style/app_styles.dart';
import '../core/style/style_profile.dart';
import '../core/style/contact_names.dart';
import '../platform/android/android_contact_names.dart';
import '../platform/linux/contact_names.dart';
import '../platform/platform_services.dart';

class AppPaths {
  const AppPaths({required this.support});

  /// App-private data directory (settings, history DB, recordings, models).
  final Directory support;

  File get settingsFile => File(p.join(support.path, 'settings.json'));
  File get usageLogFile => File(p.join(support.path, 'usage.jsonl'));
  File get historyDbFile => File(p.join(support.path, 'history.sqlite'));
  Directory get recordings => Directory(p.join(support.path, 'recordings'));
  Directory get models => Directory(p.join(support.path, 'models'));
}

final appPathsProvider = Provider<AppPaths>((ref) => throw UnimplementedError('override appPathsProvider'));
final platformServicesProvider =
    Provider<PlatformServices>((ref) => throw UnimplementedError('override platformServicesProvider'));
final initialSettingsProvider = Provider<AppSettings>((ref) => const AppSettings());

final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore(ref.watch(appPathsProvider).settingsFile));

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(initialSettingsProvider);

  /// Saves run one after another in call order, so the file always ends up
  /// with the latest state (two overlapping saves could otherwise land in the
  /// wrong order and undo a change, e.g. finishing setup).
  Future<void> _saving = Future<void>.value();

  Future<void> update(AppSettings Function(AppSettings) change) {
    state = change(state);
    final snapshot = state;
    final store = ref.read(settingsStoreProvider);
    return _saving = _saving.then((_) => store.save(snapshot), onError: (_) => store.save(snapshot));
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

/// Android package of the app the keyboard is typing into; null elsewhere.
/// Set by the keyboard on every `inputStarted`.
class CurrentPackageNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? packageName) => state = packageName;
}

final currentPackageProvider = NotifierProvider<CurrentPackageNotifier, String?>(CurrentPackageNotifier.new);

/// The style used for the next dictation: the saved style with its tone
/// resolved for [currentPackageProvider] (per-app override, built-in, global).
final effectiveStyleProvider = Provider<StyleProfile>((ref) {
  final s = ref.watch(settingsProvider);
  return s.styleProfileFor(ref.watch(currentPackageProvider));
});

/// The platform's address book, or null where there is none.
final contactNameSourceProvider = Provider<ContactNameSource?>((ref) {
  if (Platform.isAndroid) return AndroidContactNames();
  if (Platform.isLinux) return EvolutionContactNames();
  return null;
});

/// Address-book names, cached for an hour.
final contactNamesCacheProvider = Provider<ContactNamesCache?>((ref) {
  final source = ref.watch(contactNameSourceProvider);
  return source == null ? null : ContactNamesCache(source);
});

/// The style for the next request: [effectiveStyleProvider] plus, when the
/// user opted in, their contact names. Never fails; no names on any error.
final styleResolverProvider = Provider<Future<StyleProfile> Function()>((ref) {
  return () async {
    final style = ref.read(effectiveStyleProvider);
    if (!ref.read(settingsProvider).useContactNames) return style;
    final names = await ref.read(contactNamesCacheProvider)?.get() ?? const <String>[];
    return names.isEmpty ? style : style.copyWith(contactNames: names);
  };
});

final historyDbProvider = Provider<HistoryDb>((ref) {
  final file = ref.watch(appPathsProvider).historyDbFile;
  final db = HistoryDb(NativeDatabase.createInBackground(file));
  ref.onDispose(db.close);
  return db;
});

final recordingVaultProvider = Provider<RecordingVault>((ref) => RecordingVault(ref.watch(appPathsProvider).recordings));

final modelDownloaderProvider = Provider<ModelDownloads>((ref) => ModelDownloader(directory: ref.watch(appPathsProvider).models));

final geminiClientProvider = Provider<GeminiClient>((ref) {
  final c = GeminiClient();
  ref.onDispose(c.close);
  return c;
});

final geminiModelCacheProvider = Provider<GeminiModelCache>((ref) => GeminiModelCache());

final geminiEngineProvider = Provider<GeminiEngine>((ref) {
  final secrets = ref.watch(platformServicesProvider).secrets;
  return GeminiEngine(
    apiKey: secrets.readGeminiKey,
    client: ref.watch(geminiClientProvider),
    cache: ref.watch(geminiModelCacheProvider),
    preferredModel: ref.watch(settingsProvider.select((s) => s.geminiModel)),
    thinkOnCleanup: ref.watch(settingsProvider.select((s) => s.thinking)),
    healthProbe: true,
  );
});

final gemmaEngineProvider = Provider<GemmaEngine>((ref) {
  final variant = ref.watch(settingsProvider.select((s) => s.gemmaVariant));
  final downloader = ref.watch(modelDownloaderProvider);
  final engine = GemmaEngine(
    variant: variant,
    modelPath: () async {
      final f = downloader.finalFile(variant);
      return await f.exists() && await f.length() == variant.sizeBytes ? f.path : null;
    },
  );
  ref.onDispose(engine.release);
  return engine;
});

/// The engine the user picked plus the on-device fallback for cloud mode.
final engineSetProvider = Provider<Future<EngineSet> Function()>((ref) {
  return () async {
    final s = ref.read(settingsProvider);
    final gemma = ref.read(gemmaEngineProvider);
    if (s.engine == EngineKind.onDevice) return EngineSet(gemma);
    return EngineSet(ref.read(geminiEngineProvider), s.fallbackToOnDevice ? gemma : null);
  };
});

/// Live readiness of the active engine, shown on the main screen.
final activeEngineReadinessProvider = FutureProvider<EngineReadiness>((ref) async {
  final kind = ref.watch(settingsProvider.select((s) => s.engine));
  ref.watch(settingsProvider.select((s) => s.gemmaVariantId));
  final engine = kind == EngineKind.onDevice ? ref.watch(gemmaEngineProvider) : ref.watch(geminiEngineProvider);
  return engine.readiness();
});

/// Where a dictation was started from; decides whether the result is typed
/// into another app.
enum DictationOrigin { app, hotkey, keyboard }

class DictationOriginNotifier extends Notifier<DictationOrigin> {
  @override
  DictationOrigin build() => DictationOrigin.app;
  void set(DictationOrigin origin) => state = origin;
}

final dictationOriginProvider = NotifierProvider<DictationOriginNotifier, DictationOrigin>(DictationOriginNotifier.new);

/// The last insertion outcome, for UI feedback.
class LastInsertNotifier extends Notifier<InsertResult?> {
  @override
  InsertResult? build() => null;
  void set(InsertResult? r) => state = r;
}

final lastInsertProvider = NotifierProvider<LastInsertNotifier, InsertResult?>(LastInsertNotifier.new);

/// Extra work after a successful dictation (e.g. the Android keyboard commits
/// the text). Overridden by the IME entrypoint.
final outcomeHookProvider = Provider<Future<void> Function(DictationOutcome)?>((ref) => null);

/// Reads the text around the cursor at the start of a dictation. Null where
/// there is no cursor to read (overridden by the keyboard entrypoint).
final fieldContextReaderProvider = Provider<Future<FieldContext?> Function({bool screen})?>((ref) => null);

/// The on-device usage log (see [UsageLog]).
final usageLogProvider = Provider<UsageLog>((ref) => UsageLog(ref.watch(appPathsProvider).usageLogFile));

Future<void> _logUsage(Ref ref, String type, Map<String, Object?> fields) async {
  if (!ref.read(settingsProvider).usageLog) return;
  await ref.read(usageLogProvider).record(type, fields);
}

final dictationControllerProvider = Provider<DictationController>((ref) {
  final services = ref.watch(platformServicesProvider);
  final controller = DictationController(
    audio: services.audio,
    vault: ref.watch(recordingVaultProvider),
    engines: ref.watch(engineSetProvider),
    style: ref.read(styleResolverProvider),
    fieldContext: () async {
      final s = ref.read(settingsProvider);
      if (!s.useFieldContext && !s.screenContext) return null;
      final c = await ref.read(fieldContextReaderProvider)?.call(screen: s.screenContext);
      if (c == null || s.useFieldContext) return c;
      return FieldContext(screen: c.screen, field: c.field);
    },
    pipeline: const CleanupPipeline(),
    maxSession: ref.read(settingsProvider).maxSession,
    onOutcome: (outcome) async {
      final s = ref.read(settingsProvider);
      await ref.read(historyDbProvider).upsert(HistoryEntriesCompanion.insert(
            id: outcome.recordingId,
            createdAt: outcome.createdAt,
            durationMs: outcome.duration.inMilliseconds,
            cleaned: outcome.text,
            engine: outcome.engine.name,
            fellBack: Value(outcome.fellBack),
            stylePreset: Value(ref.read(effectiveStyleProvider).preset.name),
          ));
      final usage = outcome.engine == EngineKind.gemini ? GeminiClient.lastUsage : null;
      unawaited(_logUsage(ref, 'dictation', {
        'origin': ref.read(dictationOriginProvider).name,
        'app': ref.read(currentPackageProvider),
        'engine': outcome.engine.name,
        if (outcome.engine == EngineKind.gemini) 'model': GeminiClient.lastModel,
        if (outcome.engine == EngineKind.onDevice) 'model': s.gemmaVariantId,
        'audioMs': outcome.duration.inMilliseconds,
        'latencyMs': DateTime.now().difference(outcome.createdAt.add(outcome.duration)).inMilliseconds,
        'chars': outcome.text.length,
        'style': ref.read(effectiveStyleProvider).preset.name,
        'polish': s.style.polish.name,
        if (outcome.fellBack) 'fallbackReason': outcome.fallbackReason?.kind.name,
        if (usage != null) 'promptTokens': usage.prompt,
        if (usage != null) 'cachedTokens': usage.cached,
      }));
      final hook = ref.read(outcomeHookProvider);
      if (hook != null) await hook(outcome);
      if (ref.read(dictationOriginProvider) == DictationOrigin.hotkey) {
        final InsertResult result;
        if (s.typeIntoFocusedApp) {
          result = await services.inserter.insert(outcome.text);
        } else {
          await services.inserter.copy(outcome.text);
          result = const InsertResult(InsertMethod.clipboardOnly);
        }
        ref.read(lastInsertProvider.notifier).set(result);
        if (!result.delivered) {
          await services.notifier.notify(
            'Copied to clipboard',
            result.message ?? 'Paste with Ctrl+V. Ramble Voice could not type into the focused app.',
          );
        }
      }
      if (outcome.fellBack) {
        await services.notifier.notify(
          'Used on-device model',
          '${outcome.fallbackReason!.message} Cleaned with ${ModelCatalog.byId(s.gemmaVariantId)?.label ?? 'Gemma'} instead.',
        );
      }
    },
  );
  final failures = controller.states.listen((s) {
    if (s is DictationFailed) {
      appErrorLog?.call('dictation failed (${s.kind?.name ?? s.audioError?.name})', s.message, null);
      unawaited(_logUsage(ref, 'failure', {
        'origin': ref.read(dictationOriginProvider).name,
        'app': ref.read(currentPackageProvider),
        'kind': s.kind?.name ?? s.audioError?.name,
        'message': s.message,
      }));
    }
  });
  ref.onDispose(failures.cancel);
  ref.onDispose(controller.dispose);
  return controller;
});

final dictationStateProvider = StreamProvider<DictationState>((ref) async* {
  final c = ref.watch(dictationControllerProvider);
  yield c.state;
  yield* c.states;
});

/// Reports errors that the UI only summarises (set by main.dart).
void Function(String what, Object error, StackTrace? stack)? appErrorLog;

final historyProvider = StreamProvider.family<List<HistoryEntry>, String>(
  (ref, query) => ref.watch(historyDbProvider).watch(query: query).handleError((Object e, StackTrace s) {
    appErrorLog?.call('history', e, s);
    throw e;
  }),
);

/// Computes and caches the word-for-word transcript for "show original".
final verbatimProvider = FutureProvider.family<String?, String>((ref, id) async {
  final db = ref.watch(historyDbProvider);
  final entry = await db.byId(id);
  if (entry == null) return null;
  if (entry.verbatim != null) return entry.verbatim;
  final pcm = await ref.read(recordingVaultProvider).read(id);
  if (pcm == null) return null;
  final set = await ref.read(engineSetProvider)();
  final result = await const CleanupPipeline().run(
    pcm: pcm,
    style: await ref.read(styleResolverProvider)(),
    primary: set.primary,
    fallback: set.fallback,
    mode: CleanupMode.verbatim,
  );
  await db.setVerbatim(id, result.text);
  return result.text;
});

/// Recordings whose cleanup never finished (offered for retry at startup).
final pendingRecordingsProvider = FutureProvider<List<String>>((ref) => ref.watch(recordingVaultProvider).pending());

/// "Edit by voice": a separate, explicitly started controller. Normal
/// dictation never obeys spoken instructions; only this one does, and only to
/// rewrite the text it was given. Refuses to start while a dictation is
/// running.
final editControllerProvider = Provider<EditController>((ref) {
  final controller = EditController(
    audio: ref.watch(platformServicesProvider).audio,
    engines: ref.watch(engineSetProvider),
    style: ref.read(styleResolverProvider),
    isBlocked: () => ref.read(dictationControllerProvider).isBusy,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final editStateProvider = StreamProvider<EditState>((ref) async* {
  final c = ref.watch(editControllerProvider);
  yield c.state;
  yield* c.states;
});
