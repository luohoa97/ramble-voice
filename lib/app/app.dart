// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3ETheme;
import 'package:material_ui/material_ui.dart';

import '../ui/theme/app_theme.dart';
import 'providers.dart';
import 'router.dart';

/// System accent from [PlatformServices.accentColor]; null falls back to the
/// brand vermilion.
final accentColorProvider = FutureProvider<Color?>((ref) async {
  try {
    return await ref.watch(platformServicesProvider).accentColor?.call();
  } catch (_) {
    return null;
  }
});

class RambleApp extends ConsumerWidget {
  const RambleApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(accentColorProvider).value;
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Ramble Voice',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(brightness: Brightness.light, accent: accent),
      darkTheme: buildTheme(brightness: Brightness.dark, accent: accent),
      themeMode: ThemeMode.system,
      routerConfig: router,
      builder: (context, child) => M3ETheme(
        data: buildM3eTheme(Theme.of(context)),
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
