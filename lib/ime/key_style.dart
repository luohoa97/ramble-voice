// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

/// The look of the keyboard's side keys. Neutral on purpose, so the mic (the
/// accent colour) is the one thing that stands out. Use with
/// `IconButton.filledTonal(style: keyStyle(context))` or [keyFill].
ButtonStyle keyStyle(BuildContext context) {
  final c = Theme.of(context).colorScheme;
  return ButtonStyle(
    fixedSize: const WidgetStatePropertyAll(Size(56, 56)),
    minimumSize: const WidgetStatePropertyAll(Size(56, 56)),
    backgroundColor: WidgetStatePropertyAll(c.surfaceContainerHighest),
    foregroundColor: WidgetStatePropertyAll(c.onSurfaceVariant),
  );
}

/// Fill of a custom-drawn key, matching [keyStyle].
Color keyFill(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerHighest;

/// Icon and label colour on [keyFill].
Color keyForeground(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;
