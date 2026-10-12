// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/style/style_profile.dart';
import '../../widgets/adaptive_sheet.dart';

/// Custom instructions and vocabulary: the part of the style that is text.
class StyleEditor extends ConsumerStatefulWidget {
  const StyleEditor({super.key});

  @override
  ConsumerState<StyleEditor> createState() => _StyleEditorState();
}

class _StyleEditorState extends ConsumerState<StyleEditor> {
  late final TextEditingController _custom;
  final _word = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _custom = TextEditingController(text: ref.read(settingsProvider).style.customInstructions);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _custom.dispose();
    _word.dispose();
    super.dispose();
  }

  void _update(StyleProfile Function(StyleProfile) change) =>
      ref.read(settingsProvider.notifier).update((s) => s.copyWith(style: change(s.style)));

  void _addWord() {
    final w = _word.text.trim();
    if (w.isEmpty) return;
    _word.clear();
    _update((s) => s.vocabulary.any((x) => x.toLowerCase() == w.toLowerCase())
        ? s
        : s.copyWith(vocabulary: [...s.vocabulary, w]));
  }

  @override
  Widget build(BuildContext context) {
    final style = ref.watch(settingsProvider.select((s) => s.style));
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _custom,
          minLines: 3,
          maxLines: 6,
          textInputAction: TextInputAction.newline,
          decoration: const InputDecoration(
            labelText: 'Custom instructions',
            hintText: 'For example: keep British spelling, never use exclamation marks',
            alignLabelWithHint: true,
          ),
          onChanged: (v) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 500), () => _update((s) => s.copyWith(customInstructions: v)));
          },
          onTapOutside: (_) => _update((s) => s.copyWith(customInstructions: _custom.text)),
        ),
        const SizedBox(height: 24),
        Text('Vocabulary', style: t.titleMedium),
        const SizedBox(height: 2),
        Text('Names, jargon and spellings to keep.', style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
        if (style.vocabulary.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final w in style.vocabulary)
                InputChip(
                  label: Text(w),
                  deleteButtonTooltipMessage: 'Remove $w',
                  onDeleted: () => _update((s) => s.copyWith(vocabulary: [...s.vocabulary]..remove(w))),
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _word,
                decoration: const InputDecoration(labelText: 'Add a word'),
                onSubmitted: (_) => _addWord(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(tooltip: 'Add word', onPressed: _addWord, icon: const Icon(Icons.add_rounded)),
          ],
        ),
      ],
    );
  }
}

/// The editor in a sheet or dialog, for the record screen.
Future<void> showStyleEditor(BuildContext context) {
  return showAdaptiveSheet<void>(
    context,
    builder: (context) => SheetBody(
      title: 'Style',
      footer: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ),
      children: [Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom), child: const StyleEditor())],
    ),
  );
}
