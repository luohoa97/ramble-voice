// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../core/style/app_styles.dart';
import '../core/style/style_profile.dart';
import '../ui/screens/settings/polish_section.dart';
import '../ui/util/app_label.dart';

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

/// The one style chip of the keyboard: shows the tone in effect for the
/// current app ("Casual"). Its menu lists the four tones, "Use for all apps",
/// "Reset for this app" and a way to edit custom instructions.
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
    final hasOverride = pkg != null && settings.appStyles.containsKey(pkg);
    final canGlobal = pkg != null && effective != settings.style.preset;
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;

    Future<void> act(String action) {
      if (action == 'edit') {
        onEdit();
        return Future.value();
      }
      final preset = StylePreset.values.asNameMap()[action];
      if (preset != null) return setKeyboardTone(ref, preset);
      return ref.read(settingsProvider.notifier).update((s) {
        final next = {...s.appStyles}..remove(pkg);
        return action == 'all'
            ? s.copyWith(appStyles: next, style: s.style.copyWith(preset: effective))
            : s.copyWith(appStyles: next);
      });
    }

    return PopupMenuButton<String>(
      tooltip: label == null ? 'Tone' : 'Tone for $label',
      onOpened: onTick,
      onSelected: act,
      itemBuilder: (_) => [
        if (label != null)
          PopupMenuItem<String>(enabled: false, height: 32, child: Text('For $label', style: t.labelMedium)),
        for (final p in StylePreset.values)
          CheckedPopupMenuItem<String>(value: p.name, checked: p == effective, height: 40, child: Text(p.label)),
        const PopupMenuDivider(),
        const _EmbeddedEntry(child: PolishChoice()),
        const PopupMenuDivider(),
        if (canGlobal) PopupMenuItem(value: 'all', height: 40, child: Text('Use ${effective.label} for all apps')),
        if (hasOverride) const PopupMenuItem(value: 'reset', height: 40, child: Text('Reset for this app')),
        const PopupMenuItem(value: 'edit', height: 40, child: Text('Custom instructions')),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(effective.label, style: t.labelLarge?.copyWith(color: c.onSurface)),
              Icon(Icons.arrow_drop_down_rounded, size: 20, color: c.onSurface),
            ],
          ),
        ),
      ),
    );
  }
}

/// A control placed inside a popup menu that does not close it.
class _EmbeddedEntry extends PopupMenuEntry<String> {
  const _EmbeddedEntry({required this.child});

  final Widget child;

  @override
  double get height => 88;

  @override
  bool represents(String? value) => false;

  @override
  State<_EmbeddedEntry> createState() => _EmbeddedEntryState();
}

class _EmbeddedEntryState extends State<_EmbeddedEntry> {
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: widget.child);
}
