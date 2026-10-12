// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../core/cleanup/cleanup_engine.dart';
import '../../core/history/history_db.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import '../widgets/result_card.dart';

String engineLabel(HistoryEntry e) =>
    (e.engine == EngineKind.gemini.name ? 'Gemini' : 'On-device') + (e.fellBack ? ' (fallback)' : '');

/// Deletes every history row and every stored recording.
Future<void> deleteEverything(WidgetRef ref) async {
  await ref.read(historyDbProvider).deleteAll();
  final dir = ref.read(appPathsProvider).recordings;
  try {
    if (await dir.exists()) await dir.delete(recursive: true);
  } on FileSystemException {
    // Leave anything still in use; the next launch retries.
  }
  ref.invalidate(pendingRecordingsProvider);
}

Future<bool> confirmDeleteAll(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete all history?'),
      content: const Text('This removes every dictation and saved recording from this device. It cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete all')),
      ],
    ),
  );
  return ok ?? false;
}

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key, this.embedded = false});

  /// True inside the two-pane layout (no app bar of its own).
  final bool embedded;

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _query = v.trim());
    });
  }

  Future<void> _delete(HistoryEntry e) async {
    final db = ref.read(historyDbProvider);
    final vault = ref.read(recordingVaultProvider);
    await db.deleteEntry(e.id);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    var undone = false;
    messenger
        .showSnackBar(SnackBar(
          content: const Text('Deleted'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              undone = true;
              db.upsert(e.toCompanion(false));
            },
          ),
        ))
        .closed
        .then((_) {
      if (!undone) vault.delete(e.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(historyProvider(_query));
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: SearchBar(
            controller: _controller,
            hintText: 'Search history',
            leading: const Icon(Icons.search_rounded),
            elevation: const WidgetStatePropertyAll(0),
            onChanged: _onChanged,
            trailing: [
              if (_controller.text.isNotEmpty)
                IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () {
                    _controller.clear();
                    setState(() => _query = '');
                  },
                ),
            ],
          ),
        ),
        Expanded(
          child: history.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('History could not be loaded.', style: text.bodyLarge)),
            data: (items) {
              if (items.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      _query.isEmpty ? 'No dictations yet. Cleaned text appears here.' : 'Nothing matches "$_query".',
                      textAlign: TextAlign.center,
                      style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) => _HistoryTile(
                  entry: items[i],
                  onOpen: () => context.push('/history/${items[i].id}'),
                  onDelete: () => _delete(items[i]),
                ),
              );
            },
          ),
        ),
      ],
    );

    if (widget.embedded) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 8, 0),
            child: Row(
              children: [
                Expanded(child: Semantics(header: true, child: Text('History', style: text.titleLarge))),
                _DeleteAllButton(),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('History'), actions: [_DeleteAllButton()]),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 840), child: body)),
    );
  }
}

class _DeleteAllButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: 'Delete all history',
      icon: const Icon(Icons.delete_sweep_outlined),
      onPressed: () async {
        if (await confirmDeleteAll(context)) await deleteEverything(ref);
      },
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry, required this.onOpen, required this.onDelete});

  final HistoryEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final meta =
        '${formatDateTime(entry.createdAt)} · ${formatClock(Duration(milliseconds: entry.durationMs))} · ${engineLabel(entry)}';
    return Dismissible(
      key: ValueKey(entry.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: DecoratedBox(
        decoration: BoxDecoration(color: c.errorContainer, borderRadius: BorderRadius.circular(Shapes.large)),
        child: Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 20),
            child: Icon(Icons.delete_outline_rounded, color: c.onErrorContainer),
          ),
        ),
      ),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(meta, style: t.labelMedium?.copyWith(color: c.onSurfaceVariant)),
                        const SizedBox(height: 4),
                        Text(entry.cleaned, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodyLarge),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More actions',
                    onSelected: (v) {
                      if (v == 'delete') onDelete();
                    },
                    itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Delete'))],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final historyEntryProvider = FutureProvider.autoDispose.family<HistoryEntry?, String>(
  (ref, id) => ref.watch(historyDbProvider).byId(id),
);

class HistoryDetailScreen extends ConsumerWidget {
  const HistoryDetailScreen({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(historyEntryProvider(id));
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dictation'),
        actions: [
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: entry.value == null
                ? null
                : () async {
                    final e = entry.requireValue!;
                    final messenger = ScaffoldMessenger.of(context);
                    final db = ref.read(historyDbProvider);
                    final vault = ref.read(recordingVaultProvider);
                    await db.deleteEntry(id);
                    if (context.mounted) context.pop();
                    var undone = false;
                    messenger
                        .showSnackBar(SnackBar(
                          content: const Text('Deleted'),
                          action: SnackBarAction(
                            label: 'Undo',
                            onPressed: () {
                              undone = true;
                              db.upsert(e.toCompanion(false));
                            },
                          ),
                        ))
                        .closed
                        .then((_) {
                      if (!undone) vault.delete(id);
                    });
                  },
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: entry.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const Center(child: Text('This entry could not be loaded.')),
            data: (e) => e == null
                ? const Center(child: Text('This entry no longer exists.'))
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        '${formatDateTime(e.createdAt)} · ${formatClock(Duration(milliseconds: e.durationMs))} · ${engineLabel(e)}',
                        style: t.labelLarge?.copyWith(color: c.onSurfaceVariant),
                      ),
                      const SizedBox(height: 12),
                      ResultCard(text: e.cleaned, recordingId: e.id),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
