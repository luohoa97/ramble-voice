// SPDX-License-Identifier: GPL-3.0-or-later

/// Entrypoint of the Android floating mic bubble. The Kotlin
/// `RambleBubbleService` starts a headless Flutter engine (no FlutterView) on
/// [bubbleMain]; the bubble itself is native. Dictation runs through the same
/// providers as the keyboard and the text goes back to Kotlin over
/// `ramble/bubble`. This file is never the app's `main`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app/error_log.dart';
import 'app/providers.dart';
import 'core/settings/app_settings.dart';
import 'platform/android/android_model_downloads.dart';
import 'platform/android/android_services.dart';
import 'platform/android/bubble_bridge.dart';
import 'platform/platform_services.dart';

/// Dictation started from the bubble types its result into another app.
class _BubbleOrigin extends DictationOriginNotifier {
  @override
  DictationOrigin build() => DictationOrigin.keyboard;
}

/// Settings are loaded once at start; the app may change them while this
/// engine stays warm, so the service asks for a [reload] before each dictation.
class _BubbleSettings extends SettingsNotifier {
  @override
  AppSettings build() => ref.watch(initialSettingsProvider);

  Future<void> reload() async => state = await ref.read(settingsStoreProvider).load();
}

@pragma('vm:entry-point')
Future<void> bubbleMain() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Register the handlers before anything awaits so no command is dropped.
  final bridge = BubbleBridge();

  final support = await getApplicationSupportDirectory();
  installErrorLog(support);
  final paths = AppPaths(support: support);
  final settings = await SettingsStore(paths.settingsFile).load();
  final system = AndroidSystem();
  final services = PlatformServices(
    audio: AndroidAudioSource(canRequestPermission: false),
    secrets: AndroidSecretStore(),
    inserter: BubbleTextInserter(bridge),
    notifier: AndroidNotifier(),
    accentColor: system.accentColor,
    // Haptics are played natively on the bubble view.
  );

  final external = await getExternalStorageDirectory();
  final downloads = external == null ? null : AndroidModelDownloads(directory: Directory(p.join(external.path, 'models')));

  final container = ProviderContainer(
    overrides: [
      appPathsProvider.overrideWithValue(paths),
      if (downloads != null) modelDownloaderProvider.overrideWithValue(downloads),
      platformServicesProvider.overrideWithValue(services),
      initialSettingsProvider.overrideWithValue(settings),
      settingsProvider.overrideWith(_BubbleSettings.new),
      dictationOriginProvider.overrideWith(_BubbleOrigin.new),
      outcomeHookProvider.overrideWith((ref) {
        return (outcome) async {
          final result = await services.inserter.insert(outcome.text);
          ref.read(lastInsertProvider.notifier).set(result);
        };
      }),
    ],
  );

  final controller = container.read(dictationControllerProvider);
  BubbleStateRelay(controller.states, bridge);

  /// Picks up settings changed in the app, unless a dictation is in flight.
  Future<void> fresh(Future<void> Function() action) async {
    if (!controller.isBusy) await (container.read(settingsProvider.notifier) as _BubbleSettings).reload();
    await action();
  }

  bridge.onToggle = () => fresh(controller.toggle);
  bridge.onStart = () => fresh(controller.start);
  bridge.onStop = controller.stop;
  bridge.onCancel = controller.cancel;
  bridge.onRelease = () async {
    if (!controller.isBusy) await container.read(gemmaEngineProvider).release();
  };
  await bridge.ready();
}
