// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';

enum NoticeTone { info, warning, error }

/// Inline message with optional actions. Colors come from container roles.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({
    super.key,
    required this.message,
    this.tone = NoticeTone.info,
    this.icon,
    this.actions = const [],
    this.title,
  });

  final String message;
  final String? title;
  final NoticeTone tone;
  final IconData? icon;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final (bg, fg, defaultIcon) = switch (tone) {
      NoticeTone.info => (c.secondaryContainer, c.onSecondaryContainer, Icons.info_outline_rounded),
      NoticeTone.warning => (c.tertiaryContainer, c.onTertiaryContainer, Icons.warning_amber_rounded),
      NoticeTone.error => (c.errorContainer, c.onErrorContainer, Icons.error_outline_rounded),
    };
    return Semantics(
      container: true,
      liveRegion: tone == NoticeTone.error,
      child: DecoratedBox(
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Shapes.large)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(icon ?? defaultIcon, color: fg, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (title != null) Text(title!, style: t.titleSmall?.copyWith(color: fg)),
                        Text(message, style: t.bodyMedium?.copyWith(color: fg)),
                      ],
                    ),
                  ),
                ],
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Wrap(spacing: 8, runSpacing: 4, children: actions),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
