// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../core/style/app_styles.dart';
import '../core/style/style_profile.dart';
import '../ui/util/app_label.dart';
import '../ui/widgets/style_chips.dart';

/// Saves [preset] for the app the keyboard is typing into, or as the global
/// tone when the app is unknown.
Future<void> setKeyboardTone(WidgetRef ref, StylePreset preset) {
  final pkg = ref.read(currentPackageProvider);
  return ref.read(settingsProvider.notifier).update(
        (s) => pkg == null
            ? s.copyWith(style: s.style.copyWith(preset: preset))
            : s.copyWith(appStyles: {...s.appStyles, pkg: preset}),
      );
}

/// The tone chips for the keyboard. They show the tone in effect for the
/// current app; tapping one saves an override for that app.
class ToneChips extends ConsumerWidget {
  const ToneChips({super.key, required this.onEdit});

  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final pkg = ref.watch(currentPackageProvider);
    return StyleChipRow(
      compact: true,
      centered: false,
      selected: settings.styleForApp(pkg),
      hasCustom: settings.style.customInstructions.trim().isNotEmpty,
      onEdit: onEdit,
      onSelected: (p) => setKeyboardTone(ref, p),
    );
  }
}

/// "for Gmail" pill. Its menu holds "Use for all apps" and "Reset" for the
/// app's override. Hidden when the app is unknown.
class ToneHint extends ConsumerWidget {
  const ToneHint({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pkg = ref.watch(currentPackageProvider);
    if (pkg == null) return const SizedBox.shrink();
    final settings = ref.watch(settingsProvider);
    final label = ref.watch(appLabelProvider(pkg)).value ?? pkg;
    final effective = settings.styleForApp(pkg);
    final hasOverride = settings.appStyles.containsKey(pkg);
    final canGlobal = effective != settings.style.preset;
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;

    Future<void> apply(String action) {
      return ref.read(settingsProvider.notifier).update((s) {
        final next = {...s.appStyles}..remove(pkg);
        if (action == 'all') {
          return s.copyWith(appStyles: next, style: s.style.copyWith(preset: effective));
        }
        return s.copyWith(appStyles: next);
      });
    }

    return PopupMenuButton<String>(
      tooltip: 'Tone for $label',
      onSelected: apply,
      itemBuilder: (_) => [
        if (canGlobal) PopupMenuItem(value: 'all', child: Text('Use ${effective.label} for all apps')),
        if (hasOverride) const PopupMenuItem(value: 'reset', child: Text('Reset for this app')),
        if (!canGlobal && !hasOverride)
          const PopupMenuItem(enabled: false, child: Text('Tap a tone to set it for this app')),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, maxWidth: 140),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  'for $label',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.labelMedium?.copyWith(color: c.onSurfaceVariant),
                ),
              ),
              Icon(Icons.arrow_drop_down_rounded, size: 20, color: c.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
