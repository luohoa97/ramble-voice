// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/models/model_catalog.dart';
import '../../../core/models/model_downloader.dart';
import '../../../core/models/model_downloads.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../util/open_url.dart';

/// Shows the Apache-2.0 attribution. Returns true when the user accepts.
Future<bool> showModelLicense(BuildContext context) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => const _LicenseSheet(),
  );
  return ok ?? false;
}

class _LicenseSheet extends StatelessWidget {
  const _LicenseSheet();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(header: true, child: Text('Gemma model license', style: t.headlineSmall)),
          const SizedBox(height: 12),
          Text(ModelCatalog.licenseName, style: t.titleMedium),
          const SizedBox(height: 8),
          Text(ModelCatalog.attribution, style: t.bodyLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: () => openUrl(ModelCatalog.licenseUrl.toString()),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Read the license'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('I accept')),
            ],
          ),
        ],
      ),
    );
  }
}

/// All on-device model variants with download management.
class ModelSection extends ConsumerWidget {
  const ModelSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paths = ref.watch(appPathsProvider);
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final v in ModelCatalog.all) ...[
          ModelTile(variant: v),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 4),
        Text('Stored in', style: t.labelMedium?.copyWith(color: c.onSurfaceVariant)),
        SelectableText(paths.models.path, style: t.bodySmall),
      ],
    );
  }
}

class ModelTile extends ConsumerStatefulWidget {
  const ModelTile({super.key, required this.variant});

  final GemmaVariant variant;

  @override
  ConsumerState<ModelTile> createState() => _ModelTileState();
}

class _ModelTileState extends ConsumerState<ModelTile> {
  late final ModelDownloads _downloader = ref.read(modelDownloaderProvider);
  StreamSubscription<DownloadStatus>? _sub;
  late DownloadStatus _status = _downloader.statusOf(widget.variant);

  @override
  void initState() {
    super.initState();
    _sub = _downloader.watch(widget.variant).listen((s) {
      if (!mounted) return;
      final wasDone = _status is Downloaded;
      setState(() => _status = s);
      if (wasDone != (s is Downloaded)) ref.invalidate(activeEngineReadinessProvider);
    });
    _downloader.refresh(widget.variant).then((s) {
      if (mounted) setState(() => _status = s);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _download() async {
    final settings = ref.read(settingsProvider);
    if (!settings.modelLicenseAccepted) {
      final ok = await showModelLicense(context);
      if (!ok || !mounted) return;
      await ref.read(settingsProvider.notifier).update((s) => s.copyWith(modelLicenseAccepted: true));
    }
    await ref.read(settingsProvider.notifier).update((s) => s.copyWith(gemmaVariantId: widget.variant.id));
    unawaited(_downloader.start(widget.variant));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${widget.variant.label}?'),
        content: Text('This frees ${widget.variant.sizeLabel}. You can download it again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok ?? false) await _downloader.delete(widget.variant);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.variant;
    final selected = ref.watch(settingsProvider.select((s) => s.gemmaVariantId)) == v.id;
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final s = _status;

    Widget? progress;
    String? statusText;
    final actions = <Widget>[];

    switch (s) {
      case NotDownloaded():
        actions.add(FilledButton.icon(
          onPressed: _download,
          icon: const Icon(Icons.download_rounded),
          label: Text('Download ${v.sizeLabel}'),
        ));
      case Downloading(:final received, :final total, :final fraction):
        progress = LinearProgressIndicator(value: fraction, semanticsLabel: 'Download progress');
        statusText = '${formatBytes(received)} of ${formatBytes(total)} (${(fraction * 100).floor()}%)';
        actions.addAll([
          if (_downloader.supportsPause)
            FilledButton.tonalIcon(
              onPressed: () => _downloader.pause(v),
              icon: const Icon(Icons.pause_rounded),
              label: const Text('Pause'),
            ),
          if (_downloader.supportsPause)
            TextButton(onPressed: () => _downloader.delete(v), child: const Text('Cancel'))
          else
            FilledButton.tonalIcon(
              onPressed: () => _downloader.delete(v),
              icon: const Icon(Icons.close_rounded),
              label: const Text('Cancel'),
            ),
        ]);
      case Paused(:final received, :final total, :final fraction):
        progress = LinearProgressIndicator(value: fraction, semanticsLabel: 'Download paused');
        statusText = 'Paused at ${formatBytes(received)} of ${formatBytes(total)}';
        actions.addAll([
          FilledButton.icon(
            onPressed: _download,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Resume'),
          ),
          TextButton(onPressed: () => _downloader.delete(v), child: const Text('Cancel')),
        ]);
      case Verifying():
        progress = const LinearProgressIndicator(semanticsLabel: 'Verifying download');
        statusText = 'Verifying the download';
      case Downloaded():
        statusText = 'Downloaded';
        actions.add(TextButton.icon(
          onPressed: _delete,
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('Delete'),
        ));
      case DownloadFailed(:final message):
        statusText = message;
        actions.addAll([
          FilledButton.icon(
            onPressed: _download,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
          ),
          TextButton(onPressed: () => _downloader.delete(v), child: const Text('Discard')),
        ]);
    }

    final failed = s is DownloadFailed;
    return Semantics(
      container: true,
      selected: selected,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? c.secondaryContainer.withValues(alpha: 0.5) : c.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(Shapes.large),
          border: Border.all(color: selected ? c.primary : c.outlineVariant, width: selected ? 2 : 1),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(v.label, style: t.titleMedium)),
                  if (v.id == ModelCatalog.e4b.id)
                    Chip(
                      label: const Text('Recommended'),
                      backgroundColor: c.primaryContainer,
                      labelStyle: t.labelMedium?.copyWith(color: c.onPrimaryContainer),
                      side: BorderSide.none,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(v.summary, style: t.bodyMedium),
              const SizedBox(height: 4),
              Text(
                '${v.sizeLabel} download · ${v.recommendedRamGb} GB of free memory recommended',
                style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
              ),
              if (progress != null) ...[const SizedBox(height: 12), progress],
              if (statusText != null) ...[
                const SizedBox(height: 8),
                Text(statusText, style: t.bodyMedium?.copyWith(color: failed ? c.error : c.onSurfaceVariant)),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ...actions,
                  if (s is Downloaded && !selected)
                    FilledButton.tonal(
                      onPressed: () => ref
                          .read(settingsProvider.notifier)
                          .update((x) => x.copyWith(gemmaVariantId: v.id)),
                      child: const Text('Use this model'),
                    ),
                  if (s is Downloaded && selected)
                    Chip(
                      avatar: Icon(Icons.check_rounded, size: 18, color: c.onSecondaryContainer),
                      label: const Text('In use'),
                      backgroundColor: c.secondaryContainer,
                      side: BorderSide.none,
                    ),
                  TextButton(
                    onPressed: () => openUrl(v.modelCardUrl.toString()),
                    child: const Text('Model card'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
