// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../core/cleanup/cleanup_engine.dart';
import '../../core/history/history_db.dart';
import '../theme/app_theme.dart';
import '../util/clipboard.dart';
import '../util/format.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/result_panel.dart';
import '../widgets/settings_section.dart';

String engineLabel(HistoryEntry e) =>
    (e.engine == EngineKind.gemini.name ? 'Gemini' : 'On-device') +
    (e.fellBack ? ' (fallback)' : '');

IconData engineIcon(HistoryEntry e) => e.engine == EngineKind.gemini.name
    ? Icons.cloud_outlined
    : Icons.memory_rounded;

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
      content: const Text(
        'This removes every dictation and saved recording from this device. It cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete all'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Deletes [e] and offers Undo. The recording file is removed only once the
/// snackbar is gone and Undo was not used.
Future<void> deleteWithUndo(
  WidgetRef ref,
  ScaffoldMessengerState messenger,
  HistoryEntry e,
) async {
  final db = ref.read(historyDbProvider);
  final vault = ref.read(recordingVaultProvider);
  await db.deleteEntry(e.id);
  messenger.hideCurrentSnackBar();
  var undone = false;
  messenger
      .showSnackBar(
        SnackBar(
          content: const Text('Deleted'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              undone = true;
              db.upsert(e.toCompanion(false));
            },
          ),
        ),
      )
      .closed
      .then((_) {
        if (!undone) vault.delete(e.id);
      });
}

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key, this.embedded = false, this.searchFocus});

  /// True inside the two-pane layout (own header, no screen title).
  final bool embedded;

  /// Lets Ctrl+H focus the search field on desktop.
  final FocusNode? searchFocus;

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

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(historyProvider(_query));
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    final search = Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
        0,
        Space.gutter,
        Space.x1,
      ),
      child: TextField(
        controller: _controller,
        focusNode: widget.searchFocus,
        onChanged: (v) {
          setState(() {});
          _onChanged(v);
        },
        decoration: InputDecoration(
          hintText: 'Search history',
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () {
                    _controller.clear();
                    setState(() => _query = '');
                  },
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28),
            borderSide: BorderSide(color: c.primary, width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
        ),
      ),
    );

    final list = history.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('History could not be loaded.', style: t.bodyLarge),
      ),
      data: (items) {
        if (items.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(Space.x4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history_rounded, size: 40, color: c.outline),
                  const SizedBox(height: Space.x2),
                  Text(
                    _query.isEmpty
                        ? 'No dictations yet. Cleaned text appears here.'
                        : 'Nothing matches "$_query".',
                    textAlign: TextAlign.center,
                    style: t.bodyLarge?.copyWith(color: c.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, Space.x3),
          itemCount: items.length,
          itemBuilder: (context, i) => _HistoryRow(
            entry: items[i],
            onOpen: () => showHistoryDetail(context, items[i]),
            onDelete: () =>
                deleteWithUndo(ref, ScaffoldMessenger.of(context), items[i]),
          ),
        );
      },
    );

    final deleteAll = _DeleteAllButton();
    if (widget.embedded) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.x3, Space.x1, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text('History', style: t.titleLarge),
                  ),
                ),
                deleteAll,
              ],
            ),
          ),
          search,
          Expanded(child: list),
        ],
      );
    }
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          ScreenTitle('History', trailing: deleteAll),
          search,
          Expanded(child: list),
        ],
      ),
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

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.onOpen,
    required this.onDelete,
  });

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
        decoration: BoxDecoration(
          color: c.errorContainer,
          borderRadius: BorderRadius.circular(Shapes.large),
        ),
        child: Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 24),
            child: Icon(
              Icons.delete_outline_rounded,
              color: c.onErrorContainer,
            ),
          ),
        ),
      ),
      child: Semantics(
        button: true,
        label: meta,
        hint: entry.cleaned,
        excludeSemantics: true,
        onTap: onOpen,
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(Shapes.large),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: c.surfaceContainerHigh,
                    shape: BoxShape.circle,
                  ),
                  child: SizedBox.square(
                    dimension: 40,
                    child: Icon(
                      engineIcon(entry),
                      size: 20,
                      color: c.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        meta,
                        style: t.labelMedium?.copyWith(
                          color: c.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        entry.cleaned,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodyLarge,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A dictation in full: cleaned or original text, copy, share, delete.
Future<void> showHistoryDetail(BuildContext context, HistoryEntry entry) {
  return showAdaptiveSheet<void>(
    context,
    builder: (context) => _HistoryDetail(entry: entry),
  );
}

class _HistoryDetail extends ConsumerStatefulWidget {
  const _HistoryDetail({required this.entry});
  final HistoryEntry entry;

  @override
  ConsumerState<_HistoryDetail> createState() => _HistoryDetailState();
}

class _HistoryDetailState extends ConsumerState<_HistoryDetail> {
  bool _original = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final styles = RambleTextStyles.of(context);
    final share = ref.watch(platformServicesProvider).share;
    final meta =
        '${formatDateTime(e.createdAt)} · ${formatClock(Duration(milliseconds: e.durationMs))} · ${engineLabel(e)}';

    return SheetBody(
      title: 'Dictation',
      footer: Row(
        children: [
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: c.error),
            onPressed: () {
              final messenger = ScaffoldMessenger.of(context);
              Navigator.pop(context);
              deleteWithUndo(ref, messenger, e);
            },
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            label: const Text('Delete'),
          ),
          const Spacer(),
          if (share != null)
            TextButton.icon(
              onPressed: () => share(e.cleaned),
              icon: const Icon(Icons.share_rounded, size: 20),
              label: const Text('Share'),
            ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () => copyToClipboard(context, e.cleaned),
            icon: const Icon(Icons.copy_rounded, size: 20),
            label: const Text('Copy'),
          ),
        ],
      ),
      children: [
        Text(meta, style: t.labelLarge?.copyWith(color: c.onSurfaceVariant)),
        const SizedBox(height: Space.x2),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Cleaned'),
              selected: !_original,
              onSelected: (_) => setState(() => _original = false),
            ),
            ChoiceChip(
              label: const Text('Original'),
              selected: _original,
              onSelected: (_) => setState(() => _original = true),
            ),
          ],
        ),
        const SizedBox(height: Space.x3),
        if (_original)
          OriginalText(id: e.id)
        else
          SelectableText(e.cleaned, style: styles.result),
      ],
    );
  }
}
