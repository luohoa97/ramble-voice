// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/models/model_catalog.dart';
import '../../../platform/android/android_system.dart';
import '../../../core/models/model_downloader.dart';
import '../../../core/models/model_downloads.dart';
import '../../util/format.dart';
import '../../util/open_url.dart';
import '../../widgets/adaptive_sheet.dart';

/// Shows the Apache-2.0 attribution. Returns true when the user accepts.
Future<bool> showModelLicense(BuildContext context) async {
  final ok = await showAdaptiveSheet<bool>(context, builder: (context) => const _LicenseSheet());
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          const SizedBox(width: 8),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('I accept')),
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
        for (final v in ref.watch(availableVariantsProvider)) ModelRow(variant: v),
        if (ref.watch(availableVariantsProvider).any((v) => v.usesNpu)) const NpuRuntimeTile(),
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

  void _select() => ref.read(settingsProvider.notifier).update((s) => s.copyWith(gemmaVariantId: widget.variant.id));

  Future<void> _download() async {
    final settings = ref.read(settingsProvider);
    if (!settings.modelLicenseAccepted) {
      final ok = await showModelLicense(context);
      if (!ok || !mounted) return;
      await ref.read(settingsProvider.notifier).update((s) => s.copyWith(modelLicenseAccepted: true));
    }
    // One tap for the NPU model: its runtime downloads alongside it.
    final npu = widget.variant.usesNpu && !(ref.read(deviceInfoProvider).value?.npuRuntime ?? false);
    if (!mounted) return;
    if (npu && !await confirmNpuRuntime(context)) return;
    if (!mounted) return;
    _select();
    unawaited(_downloader.start(widget.variant));
    if (npu) unawaited(ref.read(npuInstallProvider.notifier).install(context, accepted: true));
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
    var status = 'Not downloaded';
    var statusColor = c.onSurfaceVariant;
    IconData? statusIcon;
    final actions = <Widget>[];

    switch (s) {
      case NotDownloaded():
        actions.add(FilledButton.tonalIcon(
          onPressed: _download,
          icon: const Icon(Icons.download_rounded, size: 20),
          label: const Text('Download'),
        ));
      case Downloading(:final received, :final total, :final fraction):
        progress = LinearProgressIndicator(value: fraction, semanticsLabel: 'Download progress');
        status = '${formatBytes(received)} of ${formatBytes(total)}, ${(fraction * 100).floor()}%';
        actions.addAll([
          if (_downloader.supportsPause)
            FilledButton.tonalIcon(
              onPressed: () => _downloader.pause(v),
              icon: const Icon(Icons.pause_rounded, size: 20),
              label: const Text('Pause'),
            ),
          if (_downloader.supportsPause)
            TextButton(onPressed: () => _downloader.delete(v), child: const Text('Cancel'))
          else
            FilledButton.tonalIcon(
              onPressed: () => _downloader.delete(v),
              icon: const Icon(Icons.close_rounded, size: 20),
              label: const Text('Cancel'),
            ),
        ]);
      case Paused(:final received, :final total, :final fraction):
        progress = LinearProgressIndicator(value: fraction, semanticsLabel: 'Download paused');
        status = 'Paused at ${formatBytes(received)} of ${formatBytes(total)}';
        actions.addAll([
          FilledButton.tonalIcon(
            onPressed: _download,
            icon: const Icon(Icons.play_arrow_rounded, size: 20),
            label: const Text('Resume'),
          ),
          TextButton(onPressed: () => _downloader.delete(v), child: const Text('Cancel')),
        ]);
      case Verifying():
        progress = const LinearProgressIndicator(semanticsLabel: 'Verifying download');
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
          TextButton(onPressed: () => _downloader.delete(v), child: const Text('Discard')),
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
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
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
                        Text(v.label, style: selected ? t.titleMedium : t.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
                        if (v.id == ModelCatalog.e4b.id)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: c.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              child: Text('Recommended', style: t.labelSmall?.copyWith(color: c.onPrimaryContainer)),
                            ),
                          ),
                        if (v.experimental)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: c.tertiaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              child: Text('Experimental', style: t.labelSmall?.copyWith(color: c.onTertiaryContainer)),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${v.summary.split('.').first} · ${v.sizeLabel} · ${v.recommendedRamGb} GB memory',
                      style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
                    ),
                    if (progress != null) ...[const SizedBox(height: 12), progress],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (statusIcon != null) ...[Icon(statusIcon, size: 16, color: c.primary), const SizedBox(width: 6)],
                        Expanded(
                          child: Semantics(
                            liveRegion: s is! Downloading,
                            child: Text(status, style: t.labelLarge?.copyWith(color: statusColor)),
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
                  if (s is Downloaded) const PopupMenuItem(value: 'delete', child: Text('Delete from this device')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Progress of the Qualcomm NPU runtime download: null when idle, 0..1 while
/// downloading; [NpuInstall.error] keeps the last failure.
class NpuInstall extends Notifier<double?> {
  String? error;

  @override
  double? build() => null;

  /// Asks for Qualcomm's license (unless [accepted]) and installs the runtime.
  /// Returns whether it is installed afterwards.
  Future<bool> install(BuildContext context, {bool accepted = false}) async {
    if (state != null) return false;
    if (!accepted && !await confirmNpuRuntime(context)) return false;
    error = null;
    state = 0;
    try {
      await AndroidSystem().installNpuRuntime(onProgress: (got, total) {
        if (total > 0) state = got / total;
      });
      return true;
    } on PlatformException catch (e) {
      error = e.message ?? e.code;
      return false;
    } finally {
      state = null;
      ref.invalidate(deviceInfoProvider);
      ref.invalidate(activeEngineReadinessProvider);
    }
  }
}

final npuInstallProvider = NotifierProvider<NpuInstall, double?>(NpuInstall.new);

/// Qualcomm's license for its NPU runtime. True when the user accepts.
Future<bool> confirmNpuRuntime(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.memory_rounded),
      title: const Text('Use the NPU?'),
      content: const Text(
        "The NPU model runs on Qualcomm's QNN runtime (about 71 MB). It is Qualcomm's proprietary software "
        'under its AI Stack license, not part of Ramble Voice. Ramble downloads it from Maven Central with the '
        "model, checks it, and keeps it on this device. Continuing accepts Qualcomm's license.",
      ),
      actions: [
        TextButton(onPressed: () => openUrl(npuRuntimeLicenseUrl), child: const Text('License')),
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Accept')),
      ],
    ),
  );
  return ok ?? false;
}

/// Status of Qualcomm's NPU runtime, with Download (one tap, after the
/// license) or Remove. The NPU model's own Download installs it too.
class NpuRuntimeTile extends ConsumerWidget {
  const NpuRuntimeTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(deviceInfoProvider).value?.npuRuntime ?? false;
    final progress = ref.watch(npuInstallProvider);
    final notifier = ref.read(npuInstallProvider.notifier);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: const Icon(Icons.memory_rounded),
      title: const Text('Qualcomm NPU runtime'),
      subtitle: Text(
        progress != null
            ? 'Downloading ${(progress * 100).round()}%'
            : notifier.error ?? (installed ? 'Installed. The NPU model can run.' : 'Needed by the NPU model. About 71 MB.'),
      ),
      trailing: progress != null
          ? SizedBox.square(dimension: 24, child: CircularProgressIndicator(value: progress == 0 ? null : progress))
          : installed
              ? TextButton(
                  onPressed: () async {
                    await AndroidSystem().removeNpuRuntime();
                    ref.invalidate(deviceInfoProvider);
                    ref.invalidate(activeEngineReadinessProvider);
                  },
                  child: const Text('Remove'),
                )
              : FilledButton.tonal(onPressed: () => notifier.install(context), child: const Text('Download')),
    );
  }
}

const npuRuntimeLicenseUrl = 'https://central.sonatype.com/artifact/com.qualcomm.qti/qnn-runtime/2.50.0';
