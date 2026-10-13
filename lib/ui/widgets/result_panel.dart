// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3ELoadingIndicator;
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../theme/app_theme.dart';
import '../util/clipboard.dart';

/// Cleaned text in emphasized type, with Copy, Share and "Show original".
/// [recordingId] keys the verbatim transcript; null hides that action.
class ResultPanel extends ConsumerStatefulWidget {
  const ResultPanel({super.key, required this.text, this.recordingId, this.footer});

  final String text;
  final String? recordingId;
  final Widget? footer;

  @override
  ConsumerState<ResultPanel> createState() => _ResultPanelState();
}

class _ResultPanelState extends ConsumerState<ResultPanel> {
  bool _showOriginal = false;

  @override
  void didUpdateWidget(ResultPanel old) {
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

    return DecoratedBox(
      decoration: BoxDecoration(color: c.surfaceContainerLow, borderRadius: BorderRadius.circular(Shapes.extraLarge)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Semantics(label: 'Cleaned text', child: SelectableText(widget.text, style: styles.result)),
            ),
            if (_showOriginal && id != null) ...[
              const SizedBox(height: 24),
              Text('Original', style: t.labelLarge?.copyWith(color: c.onSurfaceVariant)),
              const SizedBox(height: 4),
              OriginalText(id: id),
            ],
            if (widget.footer != null) ...[
              const SizedBox(height: 12),
              Padding(padding: const EdgeInsets.only(right: 8), child: widget.footer!),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton.tonalIcon(
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

/// The word-for-word transcript of recording [id], transcribed on demand.
class OriginalText extends ConsumerWidget {
  const OriginalText({super.key, required this.id});
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
                Expanded(child: SelectableText(text, style: t.bodyLarge?.copyWith(color: c.onSurfaceVariant))),
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
