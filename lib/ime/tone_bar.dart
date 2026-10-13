// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../core/style/app_styles.dart';
import '../core/style/style_profile.dart';
import '../ui/screens/settings/polish_section.dart';
import '../ui/screens/settings/style_section.dart';
import '../ui/util/app_label.dart';
import 'model_menu.dart';

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

/// The keyboard's tone chip: shows the tone in effect for the current app
/// ("Casual") and opens [TonePanel] inside the keyboard.
class ToneMenu extends ConsumerWidget {
  const ToneMenu({super.key, required this.onEdit, this.onTick});

  /// Opens custom instructions and vocabulary in the app.
  final VoidCallback onEdit;

  /// Haptic tick on press.
  final VoidCallback? onTick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final pkg = ref.watch(currentPackageProvider);
    final effective = settings.styleForApp(pkg);
    final label = pkg == null ? null : (ref.watch(appLabelProvider(pkg)).value ?? pkg);
    final open = ref.watch(keyboardPanelProvider) == KeyboardPanel.tone;
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      expanded: open,
      label: label == null ? 'Tone' : 'Tone for $label',
      excludeSemantics: false,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          onTick?.call();
          ref.read(keyboardPanelProvider.notifier).toggle(KeyboardPanel.tone);
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(effective.label, style: t.labelLarge?.copyWith(color: c.onSurface)),
                Icon(open ? Icons.arrow_drop_up_rounded : Icons.arrow_drop_down_rounded, size: 20, color: c.onSurface),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tone, polish and per-app choices, inside the keyboard (replaces the mic
/// area like the engine picker): selectable tone chips, Light/Full polish,
/// and "use for all apps", "reset for this app" and custom instructions.
class TonePanel extends ConsumerWidget {
  const TonePanel({super.key, required this.onEdit, this.onTick});

  final VoidCallback onEdit;
  final VoidCallback? onTick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final pkg = ref.watch(currentPackageProvider);
    final effective = settings.styleForApp(pkg);
    final label = pkg == null ? null : (ref.watch(appLabelProvider(pkg)).value ?? pkg);
    final hasOverride = pkg != null && settings.appStyles.containsKey(pkg);
    final canGlobal = pkg != null && effective != settings.style.preset;
    void close() => ref.read(keyboardPanelProvider.notifier).close();

    Future<void> clearOverride({required bool global}) {
      onTick?.call();
      return ref.read(settingsProvider.notifier).update((s) {
        final next = {...s.appStyles}..remove(pkg);
        return global ? s.copyWith(appStyles: next, style: s.style.copyWith(preset: effective)) : s.copyWith(appStyles: next);
      });
    }

    return KeyboardPanelFrame(
      title: label == null ? 'Tone' : 'Tone for $label',
      onClose: () {
        onTick?.call();
        close();
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final p in StylePreset.values)
                ChoiceChip(
                  label: Text(p.label),
                  selected: p == effective,
                  onSelected: (_) async {
                    onTick?.call();
                    await setKeyboardTone(ref, p);
                    close();
                  },
                ),
            ],
          ),
          if (effective == StylePreset.texting) const TextSpeakSwitch(dense: true),
          const SizedBox(height: 12),
          const PolishChoice(),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            children: [
              if (canGlobal)
                TextButton(onPressed: () => clearOverride(global: true), child: Text('Use ${effective.label} for all apps')),
              if (hasOverride) TextButton(onPressed: () => clearOverride(global: false), child: const Text('Reset for this app')),
              TextButton.icon(
                onPressed: () {
                  close();
                  onEdit();
                },
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Custom instructions'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
