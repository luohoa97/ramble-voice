// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/style/style_profile.dart';
import '../../util/app_label.dart';

/// Tones the user set for individual apps from the keyboard.
class AppStylesSection extends ConsumerWidget {
  const AppStylesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overrides = ref.watch(settingsProvider.select((s) => s.appStyles));
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;

    void setAll(Map<String, StylePreset> next) => ref
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(appStyles: next));

    final keys = overrides.keys.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Mail apps use Professional, chat apps Texting and note apps Notes. '
            'Change the tone on the keyboard and Ramble remembers it for that app.',
            style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 8),
        if (keys.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'No apps changed yet.',
              style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
            ),
          ),
        for (final pkg in keys)
          ListTile(
            contentPadding: const EdgeInsets.only(left: 16, right: 4),
            title: Text(ref.watch(appLabelProvider(pkg)).value ?? pkg),
            subtitle: Text(
              pkg,
              style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PopupMenuButton<StylePreset>(
                  tooltip:
                      'Change tone for ${ref.watch(appLabelProvider(pkg)).value ?? pkg}',
                  initialValue: overrides[pkg],
                  onSelected: (p) => setAll({...overrides, pkg: p}),
                  itemBuilder: (_) => [
                    for (final p in StylePreset.values)
                      PopupMenuItem(value: p, child: Text(p.label)),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(overrides[pkg]!.label, style: t.labelLarge),
                        const Icon(Icons.arrow_drop_down_rounded),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove override',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => setAll({...overrides}..remove(pkg)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
