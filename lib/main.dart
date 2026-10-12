// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'core/settings/app_settings.dart';
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

  final container = ProviderContainer(overrides: [
    appPathsProvider.overrideWithValue(paths),
    initialSettingsProvider.overrideWithValue(settings),
    platformServicesProvider.overrideWithValue(services),
  ]);

  if (Platform.isLinux) {
    final integration = LinuxIntegration(container);
    // Do not block first paint on portal negotiation.
    integration.start().catchError((Object e) => debugPrint('Linux integration failed: $e'));
  }

  runApp(UncontrolledProviderScope(container: container, child: const RambleApp()));
}
