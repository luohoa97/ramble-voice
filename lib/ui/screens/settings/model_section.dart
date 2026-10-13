// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/models/model_catalog.dart';
import '../../../core/models/model_downloader.dart';
import '../../../core/models/model_downloads.dart';
import '../../util/format.dart';
import '../../util/open_url.dart';
import '../../widgets/adaptive_sheet.dart';

/// Shows the Apache-2.0 attribution. Returns true when the user accepts.
Future<bool> showModelLicense(BuildContext context) async {
  final ok = await showAdaptiveSheet<bool>(
    context,
    builder: (context) => const _LicenseSheet(),
  );
  return ok ?? false;
}

class _LicenseSheet extends StatelessWidget {
  const _LicenseSheet();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SheetBody(
      title: 'Gemma model license',
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('I accept'),
          ),
        ],
      ),
      children: [
        Text(ModelCatalog.licenseName, style: t.titleMedium),
        const SizedBox(height: 8),
        Text(ModelCatalog.attribution, style: t.bodyLarge),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: () => openUrl(ModelCatalog.licenseUrl.toString()),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('Read the license'),
          ),
        ),
      ],
    );
  }
}

/// The on-device model variants, one selectable row each, with download
/// state inline.
class ModelChoices extends ConsumerWidget {
  const ModelChoices({super.key, this.showPath = false});

  /// Show where the files are stored (desktop only; the Android path is noise).
  final bool showPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final v in ModelCatalog.all) ModelRow(variant: v),
        if (showPath)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SelectableText(
              'Stored in ${ref.watch(appPathsProvider).models.path}',
              style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

class ModelRow extends ConsumerStatefulWidget {
  const ModelRow({super.key, required this.variant});

  final GemmaVariant variant;

  @override
  ConsumerState<ModelRow> createState() => _ModelRowState();
}

class _ModelRowState extends ConsumerState<ModelRow> {
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
      if (wasDone != (s is Downloaded))
        ref.invalidate(activeEngineReadinessProvider);
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

  void _select() => ref
      .read(settingsProvider.notifier)
      .update((s) => s.copyWith(gemmaVariantId: widget.variant.id));

  Future<void> _download() async {
    final settings = ref.read(settingsProvider);
    if (!settings.modelLicenseAccepted) {
      final ok = await showModelLicense(context);
      if (!ok || !mounted) return;
      await ref
          .read(settingsProvider.notifier)
          .update((s) => s.copyWith(modelLicenseAccepted: true));
    }
    _select();
    unawaited(_downloader.start(widget.variant));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${widget.variant.label}?'),
        content: Text(
          'This frees ${widget.variant.sizeLabel}. You can download it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok ?? false) await _downloader.delete(widget.variant);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.variant;
    final selected =
        ref.watch(settingsProvider.select((s) => s.gemmaVariantId)) == v.id;
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final s = _status;

    Widget? progress;
    var status = 'Not downloaded';
    var statusColor = c.onSurfaceVariant;
    IconData? statusIcon;
    final actions = <Widget>[];

    switch (s) {
      case NotDownloaded():
        actions.add(
          FilledButton.tonalIcon(
            onPressed: _download,
            icon: const Icon(Icons.download_rounded, size: 20),
            label: const Text('Download'),
          ),
        );
      case Downloading(:final received, :final total, :final fraction):
        progress = LinearProgressIndicator(
          value: fraction,
          semanticsLabel: 'Download progress',
        );
        status =
            '${formatBytes(received)} of ${formatBytes(total)}, ${(fraction * 100).floor()}%';
        actions.addAll([
          if (_downloader.supportsPause)
            FilledButton.tonalIcon(
              onPressed: () => _downloader.pause(v),
              icon: const Icon(Icons.pause_rounded, size: 20),
              label: const Text('Pause'),
            ),
          if (_downloader.supportsPause)
            TextButton(
              onPressed: () => _downloader.delete(v),
              child: const Text('Cancel'),
            )
          else
            FilledButton.tonalIcon(
              onPressed: () => _downloader.delete(v),
              icon: const Icon(Icons.close_rounded, size: 20),
              label: const Text('Cancel'),
            ),
        ]);
      case Paused(:final received, :final total, :final fraction):
        progress = LinearProgressIndicator(
          value: fraction,
          semanticsLabel: 'Download paused',
        );
        status = 'Paused at ${formatBytes(received)} of ${formatBytes(total)}';
        actions.addAll([
          FilledButton.tonalIcon(
            onPressed: _download,
            icon: const Icon(Icons.play_arrow_rounded, size: 20),
            label: const Text('Resume'),
          ),
          TextButton(
            onPressed: () => _downloader.delete(v),
            child: const Text('Cancel'),
          ),
        ]);
      case Verifying():
        progress = const LinearProgressIndicator(
          semanticsLabel: 'Verifying download',
        );
        status = 'Verifying the download';
      case Downloaded():
        status = 'Downloaded';
        statusIcon = Icons.check_circle_rounded;
      case DownloadFailed(:final message):
        status = message;
        statusColor = c.error;
        actions.addAll([
          FilledButton.tonalIcon(
            onPressed: _download,
            icon: const Icon(Icons.refresh_rounded, size: 20),
            label: const Text('Retry'),
          ),
          TextButton(
            onPressed: () => _downloader.delete(v),
            child: const Text('Discard'),
          ),
        ]);
    }

    return Semantics(
      container: true,
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      onTap: _select,
      child: InkWell(
        onTap: _select,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? c.primary : c.outline,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          v.label,
                          style: selected
                              ? t.titleMedium
                              : t.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                        ),
                        if (v.id == ModelCatalog.e4b.id)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: c.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              child: Text(
                                'Recommended',
                                style: t.labelSmall?.copyWith(
                                  color: c.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${v.summary.split('.').first} · ${v.sizeLabel} · ${v.recommendedRamGb} GB memory',
                      style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
                    ),
                    if (progress != null) ...[
                      const SizedBox(height: 12),
                      progress,
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (statusIcon != null) ...[
                          Icon(statusIcon, size: 16, color: c.primary),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Semantics(
                            liveRegion: s is! Downloading,
                            child: Text(
                              status,
                              style: t.labelLarge?.copyWith(color: statusColor),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (actions.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 4, children: actions),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More about ${v.label}',
                icon: Icon(Icons.more_vert_rounded, color: c.onSurfaceVariant),
                onSelected: (a) {
                  if (a == 'card') openUrl(v.modelCardUrl.toString());
                  if (a == 'delete') _delete();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'card', child: Text('Model card')),
                  if (s is Downloaded)
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete from this device'),
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
