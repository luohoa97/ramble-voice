// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../core/cleanup/cleanup_engine.dart';

/// Always-visible indicator of the active engine and model. Tapping opens the
/// engine picker (see `showEnginePicker`), or settings on the keyboard.
class EngineChip extends ConsumerWidget {
  const EngineChip({super.key, required this.onTap});

  final VoidCallback onTap;

  /// Builds the visible text. Public for tests and the keyboard UI.
  static String describe({
    required EngineKind engine,
    required String modelLabel,
    required AsyncValue<EngineReadiness> readiness,
  }) {
    final head = engine == EngineKind.onDevice
        ? 'On-device · $modelLabel'
        : 'Gemini';
    return readiness.when(
      data: (r) => switch (r) {
        EngineReady(:final detail) =>
          detail == null || detail.isEmpty ? head : '$head · $detail',
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
    final bg = warn ? scheme.errorContainer : scheme.surfaceContainerHigh;
    final fg = warn ? scheme.onErrorContainer : scheme.onSurface;
    return Semantics(
      button: true,
      label: 'Engine: $text. Change engine',
      excludeSemantics: true,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: Material(
            color: bg,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      warn
                          ? Icons.warning_amber_rounded
                          : settings.engine == EngineKind.onDevice
                          ? Icons.memory_rounded
                          : Icons.cloud_outlined,
                      size: 18,
                      color: fg,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge
                            ?.copyWith(color: fg),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.expand_more_rounded, size: 20, color: fg),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
