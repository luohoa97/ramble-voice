// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/style/snippets.dart';
import '../../widgets/settings_section.dart';

/// Most shortcuts kept, so the cleanup prompt stays small.
const maxSnippets = 50;

/// Spoken shortcuts: say "my email" and get the address written.
class SnippetsSection extends ConsumerWidget {
  const SnippetsSection({super.key});

  Future<void> _save(WidgetRef ref, List<Snippet> snippets) => ref
      .read(settingsProvider.notifier)
      .update((s) => s.copyWith(snippets: normaliseSnippets(snippets)));

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    List<Snippet> all, {
    int? index,
  }) async {
    final result = await showDialog<Snippet>(
      context: context,
      builder: (_) =>
          _SnippetDialog(initial: index == null ? null : all[index]),
    );
    if (result == null) return;
    final next = [...all];
    if (index == null) {
      next.add(result);
    } else {
      next[index] = result;
    }
    await _save(ref, next);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snippets = ref.watch(settingsProvider.select((s) => s.snippets));
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return SettingsSection(
      title: 'Shortcuts',
      subtitle: 'Say a phrase on its own and the expansion is written instead, like "my email" for your address.',
      children: [
        for (var i = 0; i < snippets.length; i++)
          ListTile(
            title: Text('"${snippets[i].trigger}"'),
            subtitle: Text(
              snippets[i].expansion,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => unawaited(_edit(context, ref, snippets, index: i)),
            trailing: IconButton(
              tooltip: 'Delete shortcut ${snippets[i].trigger}',
              icon: const Icon(Icons.delete_outline),
              onPressed: () =>
                  unawaited(_save(ref, [...snippets]..removeAt(i))),
            ),
          ),
        if (snippets.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'No shortcuts yet.',
              style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: snippets.length >= maxSnippets
                  ? null
                  : () => unawaited(_edit(context, ref, snippets)),
              icon: const Icon(Icons.add),
              label: const Text('Add shortcut'),
            ),
          ),
        ),
      ],
    );
  }
}

class _SnippetDialog extends StatefulWidget {
  const _SnippetDialog({this.initial});
  final Snippet? initial;

  @override
  State<_SnippetDialog> createState() => _SnippetDialogState();
}

class _SnippetDialogState extends State<_SnippetDialog> {
  late final _trigger = TextEditingController(
    text: widget.initial?.trigger ?? '',
  );
  late final _expansion = TextEditingController(
    text: widget.initial?.expansion ?? '',
  );

  @override
  void dispose() {
    _trigger.dispose();
    _expansion.dispose();
    super.dispose();
  }

  bool get _valid =>
      _trigger.text.trim().isNotEmpty && _expansion.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add shortcut' : 'Edit shortcut'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _trigger,
              autofocus: true,
              maxLength: Snippet.maxLength,
              decoration: const InputDecoration(
                labelText: 'When I say',
                hintText: 'my email',
              ),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _expansion,
              maxLength: Snippet.maxLength,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Write',
                hintText: 'me@example.com',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _valid
              ? () => Navigator.pop(
                  context,
                  Snippet(
                    trigger: _trigger.text.trim(),
                    expansion: _expansion.text.trim(),
                  ),
                )
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
