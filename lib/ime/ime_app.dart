// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../platform/android/ime_bridge.dart';
import '../ui/theme/app_theme.dart';
import 'keyboard_view.dart';

/// The keyboard service channel. Overridden in `imeMain`.
final imeBridgeProvider = Provider<ImeBridge>((ref) => throw UnimplementedError('override imeBridgeProvider'));

/// Root of the keyboard's Flutter UI.
class ImeApp extends ConsumerStatefulWidget {
  const ImeApp({super.key});

  @override
  ConsumerState<ImeApp> createState() => _ImeAppState();
}

class _ImeAppState extends ConsumerState<ImeApp> {
  Color? _accent;

  @override
  void initState() {
    super.initState();
    final bridge = ref.read(imeBridgeProvider);
    // The service is going away: stop any recording and free the model.
    bridge.onRelease = () async {
      await ref.read(dictationControllerProvider).abandon();
      await ref.read(gemmaEngineProvider).release();
    };
    unawaited(_loadAccent());
  }

  Future<void> _loadAccent() async {
    final accent = await ref.read(platformServicesProvider).accentColor?.call();
    if (mounted && accent != null) setState(() => _accent = accent);
  }

  @override
  void dispose() {
    ref.read(imeBridgeProvider).onRelease = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Ramble Voice',
      themeMode: ThemeMode.system,
      theme: buildTheme(brightness: Brightness.light, accent: _accent),
      darkTheme: buildTheme(brightness: Brightness.dark, accent: _accent),
      home: const KeyboardView(),
    );
  }
}
