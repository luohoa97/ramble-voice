// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/style/style_profile.dart';
import '../../widgets/settings_section.dart';

/// Light or Full polish, as a segmented control with a one-line explanation.
/// [PolishChoice] is the bare control, for menus (the keyboard style menu).
class PolishSection extends StatelessWidget {
  const PolishSection({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsSection(
      title: 'Polish',
      children: [Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: PolishChoice())],
    );
  }
}

class PolishChoice extends ConsumerWidget {
  const PolishChoice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final polish = ref.watch(settingsProvider.select((s) => s.style.polish));
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedButton<Polish>(
          segments: [for (final p in Polish.values) ButtonSegment(value: p, label: Text(p.label))],
          selected: {polish},
          showSelectedIcon: false,
          onSelectionChanged: (v) => unawaited(
            ref.read(settingsProvider.notifier).update((s) => s.copyWith(style: s.style.copyWith(polish: v.first))),
          ),
        ),
        const SizedBox(height: 8),
        Text(polish.description, style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
      ],
    );
  }
}
