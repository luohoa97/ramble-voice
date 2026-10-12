// SPDX-License-Identifier: GPL-3.0-or-later

/// Entrypoint of the Android keyboard. The Kotlin `RambleImeService` starts a
/// dedicated Flutter engine on [imeMain]; its UI is rendered in the keyboard
/// window. This file is never the app's `main`.
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
import 'ime/edit_session.dart';
import 'ime/ime_app.dart';
import 'platform/android/android_model_downloads.dart';
import 'platform/android/android_services.dart';
import 'platform/android/ime_auto_start.dart';
import 'platform/platform_services.dart';

/// Dictation started from the keyboard types its result into the focused field.
class _KeyboardOrigin extends DictationOriginNotifier {
  @override
  DictationOrigin build() => DictationOrigin.keyboard;
}

@pragma('vm:entry-point')
Future<void> imeMain() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Register the channel handler before anything awaits so the first
  // `inputStarted` from the service is not dropped.
  final bridge = ImeBridge();

  final support = await getApplicationSupportDirectory();
  installErrorLog(support);
  final paths = AppPaths(support: support);
  final settings = await SettingsStore(paths.settingsFile).load();
  final services = await createAndroidServices(keyboard: true, bridge: bridge);

  // Models are downloaded by the app into <externalFilesDir>/models; the
  // keyboard only reads them, so it needs the path but not the service.
  final external = await getExternalStorageDirectory();
  final downloads = external == null
      ? null
      : AndroidModelDownloads(
          directory: Directory(p.join(external.path, 'models')),
        );

  final container = ProviderContainer(
    overrides: [
      appPathsProvider.overrideWithValue(paths),
      if (downloads != null)
        modelDownloaderProvider.overrideWithValue(downloads),
      platformServicesProvider.overrideWithValue(services),
      initialSettingsProvider.overrideWithValue(settings),
      imeBridgeProvider.overrideWithValue(bridge),
      dictationOriginProvider.overrideWith(_KeyboardOrigin.new),
      outcomeHookProvider.overrideWith((ref) {
        return (outcome) async {
          final result = await services.inserter.insert(outcome.text);
          ref.read(lastInsertProvider.notifier).set(result);
          if (result.method == InsertMethod.typed) {
            ref
                .read(lastDictationProvider.notifier)
                .set(
                  LastDictation(
                    text: outcome.text,
                    packageName: bridge.current.packageName,
                  ),
                );
          }
          // Ramble is for dictation; typing stays in Gboard. Hop back after
          // a short pause that leaves time for Undo.
          if (result.delivered && ref.read(settingsProvider).autoSwitchBack) {
            unawaited(
              Future<void>.delayed(
                const Duration(milliseconds: 1500),
                () async {
                  if (ref.read(lastInsertProvider) == result) {
                    await bridge.switchToPreviousInputMethod(auto: true);
                  }
                },
              ),
            );
          }
        };
      }),
    ],
  );

  // The floating mic switches to this keyboard and expects it to listen.
  final controller = container.read(dictationControllerProvider);
  ImeAutoStart(
    bridge: bridge,
    onStart: () {
      container
          .read(dictationOriginProvider.notifier)
          .set(DictationOrigin.keyboard);
      return controller.start();
    },
    onStop: controller.stop,
  );

  runApp(
    UncontrolledProviderScope(container: container, child: const ImeApp()),
  );
}
