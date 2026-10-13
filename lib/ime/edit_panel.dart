// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../ui/util/format.dart';
import 'edit_session.dart';
import 'key_style.dart';

/// The Edit key: starts "edit what you said by voice". 56 dp, with the same
/// look as the other side keys.
class EditKey extends ConsumerWidget {
  const EditKey({super.key, this.enabled = true});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton.filledTonal(
      onPressed: enabled
          ? () => unawaited(ref.read(imeEditProvider.notifier).begin())
          : null,
      icon: const Icon(Icons.edit_note),
      tooltip: 'Edit by voice',
      style: keyStyle(context),
    );
  }
}

/// Replaces the mic area while an edit is in progress: what is being edited,
/// the live listening state, the result and Undo.
class EditPanel extends ConsumerWidget {
  const EditPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final edit = ref.watch(imeEditProvider);
    final notifier = ref.read(imeEditProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final source = edit.source?.label;
    final (IconData icon, String title, String? hint) = switch (edit.phase) {
      EditPhase.idle ||
      EditPhase.resolving => (Icons.edit_note, 'Looking at the field', null),
      EditPhase.listening => (
        Icons.mic,
        edit.listening == null
            ? 'Starting microphone'
            : 'Say your edit  ${formatClock(edit.listening!.elapsed)}',
        'For example: make it shorter, fix the name, translate to French',
      ),
      EditPhase.processing => (Icons.auto_fix_high, 'Editing', null),
      EditPhase.applied when edit.unchanged => (
        Icons.info_outline,
        'No change made',
        'Try saying the edit again',
      ),
      EditPhase.applied => (Icons.check_circle_outline, 'Edited', null),
      EditPhase.failed => (
        Icons.error_outline,
        edit.message ?? 'The edit failed',
        null,
      ),
    };
    final failed = edit.phase == EditPhase.failed;

    return Semantics(
      liveRegion: true,
      container: true,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (source != null && !failed)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Chip(
                avatar: const Icon(Icons.edit_note, size: 18),
                label: Text(source),
                visualDensity: VisualDensity.compact,
              ),
            ),
          if (edit.phase == EditPhase.listening)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: LinearProgressIndicator(
                value: edit.listening?.level.clamp(0.04, 1.0),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 22,
                color: failed ? scheme.error : scheme.primary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                hint,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              if (edit.phase == EditPhase.listening)
                FilledButton.icon(
                  onPressed: edit.listening == null
                      ? null
                      : () => unawaited(notifier.finish()),
                  icon: const Icon(Icons.stop),
                  label: const Text('Done'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                ),
              if (edit.phase == EditPhase.applied && edit.undoable)
                FilledButton.tonalIcon(
                  onPressed: () => unawaited(notifier.undo()),
                  icon: const Icon(Icons.undo),
                  label: const Text('Undo'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                ),
              if (edit.phase == EditPhase.failed)
                FilledButton.tonal(
                  onPressed: () => unawaited(notifier.begin()),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  child: const Text('Try again'),
                ),
              if (edit.phase != EditPhase.processing)
                TextButton(
                  onPressed: () => unawaited(notifier.dismiss()),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: Text(
                    edit.phase == EditPhase.listening ? 'Cancel' : 'Close',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
