// SPDX-License-Identifier: GPL-3.0-or-later

/// Entrypoint of the Android keyboard. The Kotlin `RambleImeService` starts a
/// dedicated Flutter engine on [imeMain]; its UI is rendered in the keyboard
/// window. This file is never the app's `main`.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/providers.dart';
import 'core/settings/app_settings.dart';
import 'ime/ime_app.dart';
import 'platform/android/android_services.dart';

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
  final paths = AppPaths(support: support);
  final settings = await SettingsStore(paths.settingsFile).load();
  final services = await createAndroidServices(keyboard: true, bridge: bridge);

  runApp(
    ProviderScope(
      overrides: [
        appPathsProvider.overrideWithValue(paths),
        platformServicesProvider.overrideWithValue(services),
        initialSettingsProvider.overrideWithValue(settings),
        imeBridgeProvider.overrideWithValue(bridge),
        dictationOriginProvider.overrideWith(_KeyboardOrigin.new),
        outcomeHookProvider.overrideWith((ref) {
          return (outcome) async {
            final result = await services.inserter.insert(outcome.text);
            ref.read(lastInsertProvider.notifier).set(result);
          };
        }),
      ],
      child: const ImeApp(),
    ),
  );
}
