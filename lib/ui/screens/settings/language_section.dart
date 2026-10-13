// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/style/languages.dart';
import '../../widgets/settings_section.dart';

/// The languages the user speaks. The cleanup writes every word in the
/// language it was spoken in and never translates; no selection means any
/// language is accepted.
class LanguageSection extends ConsumerWidget {
  const LanguageSection({super.key});

  Future<void> _save(WidgetRef ref, List<String> codes) =>
      ref.read(settingsProvider.notifier).update((s) => s.copyWith(languages: Languages.normaliseList(codes)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(settingsProvider.select((s) => s.languages));
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return SettingsSection(
      title: 'Languages',
      subtitle: 'Pick the languages you speak. Words stay in the language you said them in, '
          'so "calendar" never turns into "calendario".',
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (selected.isEmpty)
                Chip(
                  avatar: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Detect any language'),
                  backgroundColor: c.secondaryContainer,
                ),
              for (final code in selected)
                InputChip(
                  label: Text(Languages.displayName(code)),
                  onDeleted: () => unawaited(_save(ref, [...selected]..remove(code))),
                  deleteButtonTooltipMessage: 'Remove ${Languages.displayName(code)}',
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('Add language'),
                onPressed: () async {
                  final picked = await showDialog<List<String>>(
                    context: context,
                    builder: (_) => _LanguagePicker(initial: selected),
                  );
                  if (picked != null) await _save(ref, picked);
                },
              ),
            ],
          ),
        ),
        if (selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => unawaited(_save(ref, const [])),
                child: const Text('Detect any language'),
              ),
            ),
          ),
        if (selected.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Without a choice the model guesses, and may translate short words.',
              style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

class _LanguagePicker extends StatefulWidget {
  const _LanguagePicker({required this.initial});
  final List<String> initial;

  @override
  State<_LanguagePicker> createState() => _LanguagePickerState();
}

class _LanguagePickerState extends State<_LanguagePicker> {
  late final Set<String> _chosen = {...widget.initial};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final l in Languages.all)
        if (q.isEmpty || l.name.toLowerCase().contains(q) || l.code.contains(q)) l,
    ];
    return AlertDialog(
      title: const Text('Languages'),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search languages'),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final l in shown)
                    CheckboxListTile(
                      value: _chosen.contains(l.code),
                      title: Text(l.name),
                      dense: true,
                      onChanged: (on) => setState(() => on == true ? _chosen.add(l.code) : _chosen.remove(l.code)),
                    ),
                  if (shown.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No match')),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _chosen.toList()), child: const Text('Done')),
      ],
    );
  }
}
