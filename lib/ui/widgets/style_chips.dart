// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../core/style/style_profile.dart';

/// One-tap tone picker: Casual, Professional, Texting, Notes. A "Custom" chip
/// appears while custom instructions are set and opens the editor; it marks
/// that those instructions apply on top of the chosen tone.
///
/// Long-pressing any chip, or the tune button, opens style editing.
class StyleChipRow extends StatelessWidget {
  const StyleChipRow({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.hasCustom,
    required this.onEdit,
    this.compact = false,
    this.centered = true,
    this.gutter = 16,
    this.showEditButton = true,
  });

  final StylePreset selected;
  final ValueChanged<StylePreset> onSelected;
  final bool hasCustom;

  /// Opens custom instructions and vocabulary. Null when the editor is already
  /// on screen: the Custom chip and the edit button are then left out.
  final VoidCallback? onEdit;
  final bool compact;
  final bool centered;

  /// Side padding of the scrolling row.
  final double gutter;

  /// The pencil at the end of the row. A narrow screen puts it elsewhere.
  final bool showEditButton;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final density = compact ? VisualDensity.compact : VisualDensity.standard;

    final chips = <Widget>[
      for (final p in StylePreset.values)
        GestureDetector(
          onLongPress: onEdit,
          child: ChoiceChip(
            label: Text(p.label),
            selected: selected == p,
            visualDensity: density,
            showCheckmark: true,
            labelStyle: t.labelLarge?.copyWith(
              color: selected == p
                  ? c.onSecondaryContainer
                  : c.onSurfaceVariant,
              fontWeight: selected == p ? FontWeight.w700 : FontWeight.w500,
            ),
            onSelected: (_) => onSelected(p),
          ),
        ),
      if (hasCustom && onEdit != null)
        ActionChip(
          avatar: Icon(
            Icons.tune_rounded,
            size: 18,
            color: c.onTertiaryContainer,
          ),
          label: const Text('Custom'),
          visualDensity: density,
          backgroundColor: c.tertiaryContainer,
          labelStyle: t.labelLarge?.copyWith(color: c.onTertiaryContainer),
          tooltip: 'Your custom instructions are on. Tap to edit',
          onPressed: onEdit,
        ),
    ];
    final editButton = onEdit == null || !showEditButton
        ? null
        : IconButton(
            tooltip: 'Edit custom instructions and vocabulary',
            visualDensity: density,
            onPressed: onEdit,
            icon: Icon(Icons.edit_outlined, color: c.onSurfaceVariant),
          );

    final gap = compact ? 6.0 : 8.0;
    Widget body;
    if (compact) {
      // The keyboard has one line: scroll sideways instead of wrapping.
      body = Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.only(left: gutter),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < chips.length; i++) ...[
                    if (i > 0) SizedBox(width: gap),
                    chips[i],
                  ],
                ],
              ),
            ),
          ),
          ?editButton,
        ],
      );
    } else {
      body = Padding(
        padding: EdgeInsets.symmetric(horizontal: gutter),
        child: Wrap(
          alignment: centered ? WrapAlignment.center : WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: gap,
          runSpacing: 4,
          children: [...chips, ?editButton],
        ),
      );
    }

    return Semantics(container: true, label: 'Tone', child: body);
  }
}

/// [StyleChipRow] bound to the saved tone (the app, not the keyboard).
class StyleChips extends ConsumerWidget {
  const StyleChips({
    super.key,
    this.onEdit,
    this.centered = true,
    this.gutter = 16,
    this.showEditButton = true,
  });

  final VoidCallback? onEdit;
  final bool centered;
  final double gutter;
  final bool showEditButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(settingsProvider.select((s) => s.style));
    return StyleChipRow(
      selected: style.preset,
      hasCustom: style.customInstructions.trim().isNotEmpty,
      centered: centered,
      gutter: gutter,
      showEditButton: showEditButton,
      onEdit: onEdit,
      onSelected: (p) => ref
          .read(settingsProvider.notifier)
          .update((s) => s.copyWith(style: s.style.copyWith(preset: p))),
    );
  }
}
