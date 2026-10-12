// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../core/cleanup/cleanup_engine.dart';

/// Always-visible indicator of the active engine. Tapping opens settings.
class EngineChip extends ConsumerWidget {
  const EngineChip({super.key, required this.onTap});

  final VoidCallback onTap;

  /// Builds the visible text. Public for tests and the keyboard UI.
  static String describe({
    required EngineKind engine,
    required String modelLabel,
    required AsyncValue<EngineReadiness> readiness,
  }) {
    final head = engine == EngineKind.onDevice ? 'On-device · $modelLabel' : 'Gemini';
    return readiness.when(
      data: (r) => switch (r) {
        EngineReady(:final detail) => detail == null || detail.isEmpty ? head : '$head · $detail',
        EngineNotReady() => '$head · ${_short(r)}',
      },
      loading: () => '$head · Checking',
      error: (_, _) => '$head · Unavailable',
    );
  }

  static String _short(EngineNotReady r) => switch (r.reason) {
        CleanupFailureKind.modelNotDownloaded => 'Model not downloaded',
        CleanupFailureKind.missingApiKey => 'No API key',
        CleanupFailureKind.invalidApiKey => 'Invalid API key',
        CleanupFailureKind.noNetwork => 'Offline',
        _ => 'Not ready',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final readiness = ref.watch(activeEngineReadinessProvider);
    final text = describe(
      engine: settings.engine,
      modelLabel: settings.gemmaVariant.label,
      readiness: readiness,
    );
    final warn = readiness.hasValue && readiness.requireValue is EngineNotReady;
    final scheme = Theme.of(context).colorScheme;
    final fg = warn ? scheme.onErrorContainer : scheme.onSecondaryContainer;
    return Semantics(
      button: true,
      label: 'Engine: $text. Opens settings',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: ActionChip(
            onPressed: onTap,
            backgroundColor: warn ? scheme.errorContainer : scheme.secondaryContainer,
            side: BorderSide.none,
            avatar: Icon(
              warn
                  ? Icons.warning_amber_rounded
                  : settings.engine == EngineKind.onDevice
                      ? Icons.memory_rounded
                      : Icons.cloud_outlined,
              size: 18,
              color: fg,
            ),
            label: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: fg)),
            tooltip: 'Change engine in settings',
          ),
        ),
      ),
    );
  }
}
