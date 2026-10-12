// SPDX-License-Identifier: GPL-3.0-or-later

/// Entrypoint of the Android keyboard. The Kotlin `RambleImeService` starts a
/// dedicated Flutter engine on [imeMain]; its UI is rendered in the keyboard
/// window. This file is never the app's `main`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app/providers.dart';
import 'core/settings/app_settings.dart';
import 'ime/ime_app.dart';
import 'platform/android/android_model_downloads.dart';
import 'platform/android/android_services.dart';

/// Dictation started from the keyboard types its result into the focused field.
class _KeyboardOrigin extends DictationOriginNotifier {
  @override
  DictationOrigin build() => DictationOrigin.keyboard;
}

/// Appends Flutter/Dart errors from the keyboard engine to
/// Android/data/<package>/files/logs/dart.log (local only, never uploaded).
Future<void> _installDartCrashLog() async {
  final ext = await getExternalStorageDirectory();
  if (ext == null) return;
  final log = File(p.join(ext.path, 'logs', 'dart.log'));
  await log.parent.create(recursive: true);
  void write(String what, Object error, StackTrace? stack) {
    try {
      log.writeAsStringSync('${DateTime.now().toIso8601String()} $what: $error\n$stack\n\n', mode: FileMode.append);
    } catch (_) {}
  }

  write('ime start', 'imeMain', null);
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    write('FlutterError', details.exception, details.stack);
    previous?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    write('uncaught', error, stack);
    return false;
  };
}

@pragma('vm:entry-point')
Future<void> imeMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _installDartCrashLog();

  // Register the channel handler before anything awaits so the first
  // `inputStarted` from the service is not dropped.
  final bridge = ImeBridge();

  final support = await getApplicationSupportDirectory();
  final paths = AppPaths(support: support);
  final settings = await SettingsStore(paths.settingsFile).load();
  final services = await createAndroidServices(keyboard: true, bridge: bridge);

  // Models are downloaded by the app into <externalFilesDir>/models; the
  // keyboard only reads them, so it needs the path but not the service.
  final external = await getExternalStorageDirectory();
  final downloads = external == null ? null : AndroidModelDownloads(directory: Directory(p.join(external.path, 'models')));

  runApp(
    ProviderScope(
      overrides: [
        appPathsProvider.overrideWithValue(paths),
        if (downloads != null) modelDownloaderProvider.overrideWithValue(downloads),
        platformServicesProvider.overrideWithValue(services),
        initialSettingsProvider.overrideWithValue(settings),
        imeBridgeProvider.overrideWithValue(bridge),
        dictationOriginProvider.overrideWith(_KeyboardOrigin.new),
        outcomeHookProvider.overrideWith((ref) {
          return (outcome) async {
            final result = await services.inserter.insert(outcome.text);
            ref.read(lastInsertProvider.notifier).set(result);
            // Ramble is for dictation; typing stays in Gboard. Hop back after
            // a short pause that leaves time for Undo.
            if (result.delivered && ref.read(settingsProvider).autoSwitchBack) {
              unawaited(Future<void>.delayed(const Duration(milliseconds: 1500), () async {
                if (ref.read(lastInsertProvider) == result) await bridge.switchToPreviousInputMethod();
              }));
            }
          };
        }),
      ],
      child: const ImeApp(),
    ),
  );
}
