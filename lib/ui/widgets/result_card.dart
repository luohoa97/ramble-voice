// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3ELoadingIndicator;
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../theme/app_theme.dart';
import '../util/clipboard.dart';

/// Cleaned text in emphasized type, with copy, share and "Show original".
/// [recordingId] keys the verbatim transcript; null hides that action.
class ResultCard extends ConsumerStatefulWidget {
  const ResultCard({super.key, required this.text, this.recordingId, this.footer});

  final String text;
  final String? recordingId;
  final Widget? footer;

  @override
  ConsumerState<ResultCard> createState() => _ResultCardState();
}

class _ResultCardState extends ConsumerState<ResultCard> {
  bool _showOriginal = false;

  @override
  void didUpdateWidget(ResultCard old) {
    super.didUpdateWidget(old);
    if (old.recordingId != widget.recordingId) _showOriginal = false;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final styles = RambleTextStyles.of(context);
    final share = ref.watch(platformServicesProvider).share;
    final id = widget.recordingId;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: 'Cleaned text',
              child: SelectableText(widget.text, style: styles.result),
            ),
            if (_showOriginal && id != null) ...[
              const SizedBox(height: 16),
              Divider(color: c.outlineVariant),
              const SizedBox(height: 12),
              Text('Original', style: t.labelLarge?.copyWith(color: c.onSurfaceVariant)),
              const SizedBox(height: 4),
              _Original(id: id),
            ],
            if (widget.footer != null) ...[const SizedBox(height: 8), widget.footer!],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: () => copyToClipboard(context, widget.text),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copy'),
                ),
                if (share != null)
                  TextButton.icon(
                    onPressed: () => share(widget.text),
                    icon: const Icon(Icons.share_rounded, size: 18),
                    label: const Text('Share'),
                  ),
                if (id != null)
                  TextButton.icon(
                    onPressed: () => setState(() => _showOriginal = !_showOriginal),
                    icon: Icon(_showOriginal ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                    label: Text(_showOriginal ? 'Hide original' : 'Show original'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Original extends ConsumerWidget {
  const _Original({required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(verbatimProvider(id));
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return v.when(
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            M3ELoadingIndicator(size: 32, color: c.primary, semanticLabel: 'Transcribing the original'),
            const SizedBox(width: 12),
            Expanded(child: Text('Transcribing the recording word for word', style: t.bodyMedium)),
          ],
        ),
      ),
      error: (e, _) => Text(
        'The original could not be transcribed. Try again later.',
        style: t.bodyMedium?.copyWith(color: c.error),
      ),
      data: (text) => text == null
          ? Text('The original recording is no longer available.', style: t.bodyMedium)
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: SelectableText(text, style: t.bodyLarge)),
                IconButton(
                  tooltip: 'Copy original',
                  onPressed: () => copyToClipboard(context, text, message: 'Original copied'),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                ),
              ],
            ),
    );
  }
}
