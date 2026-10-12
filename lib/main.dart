// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

// Secondary engine entrypoints (Android keyboard, floating mic). Release AOT
// builds only include libraries reachable from main.dart, so import them here
// or their @pragma('vm:entry-point') functions are tree-shaken away.
// ignore: unused_import
import 'main_ime.dart';
// ignore: unused_import
import 'main_bubble.dart';
import 'app/app.dart';
import 'app/providers.dart';
import 'core/models/model_catalog.dart';
import 'core/models/model_downloads.dart';
import 'core/settings/app_settings.dart';
import 'platform/android/android_model_downloads.dart';
import 'platform/android/android_services.dart';
import 'platform/linux/linux_services.dart';
import 'platform/platform_services.dart';
import 'ui/linux_wiring.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(['Roboto Flex'], text);
  });

  if (Platform.isAndroid) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  final support = await getApplicationSupportDirectory();
  final paths = AppPaths(support: support);
  final settings = await SettingsStore(paths.settingsFile).load();
  final PlatformServices services = Platform.isLinux ? await createLinuxServices() : await createAndroidServices();

  // Android downloads run in the system DownloadManager so they survive the
  // app being backgrounded, swiped away or the device rebooting.
  final ModelDownloads? androidDownloads = Platform.isAndroid ? await AndroidModelDownloads.create() : null;

  final container = ProviderContainer(overrides: [
    if (androidDownloads != null) modelDownloaderProvider.overrideWithValue(androidDownloads),
    appPathsProvider.overrideWithValue(paths),
    initialSettingsProvider.overrideWithValue(settings),
    platformServicesProvider.overrideWithValue(services),
  ]);

  // Pick up downloads that finished while the app was closed.
  final downloads = container.read(modelDownloaderProvider);
  for (final v in ModelCatalog.all) {
    unawaited(downloads.refresh(v).catchError((Object e) {
      debugPrint('Model refresh failed: $e');
      return downloads.statusOf(v);
    }));
  }

  if (Platform.isLinux) {
    final integration = LinuxIntegration(container);
    // Do not block first paint on portal negotiation.
    integration.start().catchError((Object e) => debugPrint('Linux integration failed: $e'));
  }

  runApp(UncontrolledProviderScope(container: container, child: const RambleApp()));
}
