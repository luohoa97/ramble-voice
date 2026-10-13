// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

/// A flat settings group: a small accent header, then rows. No card, no
/// border; grouping comes from spacing and the header alone.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: t.titleSmall?.copyWith(color: c.primary),
              ),
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                subtitle!,
                style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
              ),
            ),
          ...children,
        ],
      ),
    );
  }
}

/// Large screen title used instead of an app bar.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.title, {super.key, this.leading, this.trailing});

  final String title;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 16),
      child: Row(
        children: [
          if (leading != null) leading! else const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title, style: t.headlineMedium),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
