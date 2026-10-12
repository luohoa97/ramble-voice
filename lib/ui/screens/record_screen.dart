// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../core/audio/audio_source.dart';
import '../../core/cleanup/cleanup_engine.dart';
import '../../core/dictation/dictation_controller.dart';
import '../theme/app_theme.dart';
import '../util/clipboard.dart';
import '../util/format.dart';
import '../util/platform_flags.dart';
import '../widgets/engine_chip.dart';
import '../widgets/engine_picker.dart';
import '../widgets/limit_chip.dart';
import '../widgets/mic_button.dart';
import '../widgets/notice_banner.dart';
import '../widgets/result_panel.dart';
import '../widgets/style_chips.dart';
import 'settings/style_section.dart';

/// Plain-language reason for a fallback, e.g. "Gemini was rate limited".
String fallbackNotice(CleanupFailure reason) {
  final why = switch (reason.kind) {
    CleanupFailureKind.rateLimited => 'Gemini was rate limited',
    CleanupFailureKind.dailyQuotaExceeded => 'The Gemini daily limit was reached',
    CleanupFailureKind.noNetwork => 'There is no internet connection',
    CleanupFailureKind.server => 'Gemini was unavailable',
    CleanupFailureKind.audioTooLong => 'The recording was too long for Gemini',
    _ => 'Gemini could not be used',
  };
  return '$why, cleaned on-device instead';
}

/// True while a text field has focus, so Space and Enter type instead of
/// toggling the recording.
bool _typing() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  return ctx != null && ctx.findAncestorStateOfType<EditableTextState>() != null;
}

class RecordScreen extends ConsumerStatefulWidget {
  const RecordScreen({super.key, this.trailing});

  /// Placed at the end of the top row (the settings button on desktop).
  final Widget? trailing;

  @override
  ConsumerState<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends ConsumerState<RecordScreen> {
  DictationController get _controller => ref.read(dictationControllerProvider);

  void _haptic(String kind) {
    if (!ref.read(settingsProvider).haptics) return;
    ref.read(platformServicesProvider).haptic?.call(kind);
  }

  void _toggle() {
    ref.read(dictationOriginProvider.notifier).set(DictationOrigin.app);
    ref.read(lastInsertProvider.notifier).set(null);
    _controller.toggle();
  }

  void _holdStart() {
    ref.read(dictationOriginProvider.notifier).set(DictationOrigin.app);
    ref.read(lastInsertProvider.notifier).set(null);
    _controller.start();
  }

  void _holdEnd() => _controller.stop();

  void _cancel() {
    final s = _controller.state;
    if (s is DictationListening || s is DictationStarting) {
      _controller.cancel();
    } else if (s is DictationDone || s is DictationFailed) {
      _controller.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<DictationState>>(dictationStateProvider, (prev, next) {
      final a = prev?.value;
      final b = next.value;
      if (b == null || a.runtimeType == b.runtimeType) return;
      switch (b) {
        case DictationListening():
          _haptic('start');
        case DictationProcessing():
          _haptic('stop');
        case DictationDone():
          _haptic('done');
          ref.invalidate(pendingRecordingsProvider);
        case DictationFailed():
          _haptic('error');
          ref.invalidate(pendingRecordingsProvider);
        default:
          break;
      }
    });

    final state = ref.watch(dictationStateProvider).value ?? const DictationIdle();
    final isLinux = ref.watch(isLinuxProvider);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final styles = RambleTextStyles.of(context);

    final status = switch (state) {
      DictationIdle(:final notice) => notice ?? (isLinux ? 'Press Space or click to dictate' : 'Tap to dictate'),
      DictationStarting() => 'Starting microphone',
      DictationListening() => 'Listening',
      DictationProcessing(:final progress) => progress != null && progress.chunks > 1
          ? 'Cleaning up, part ${progress.chunk} of ${progress.chunks}'
          : 'Cleaning up',
      DictationDone() => 'Done',
      DictationFailed() => 'Something went wrong',
    };

    void toggleUnlessTyping() {
      if (!_typing()) _toggle();
    }

    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.escape): _cancel,
      const SingleActivator(LogicalKeyboardKey.space): toggleUnlessTyping,
      const SingleActivator(LogicalKeyboardKey.enter): toggleUnlessTyping,
      if (state is DictationDone)
        const SingleActivator(LogicalKeyboardKey.keyC, control: true): () => copyToClipboard(context, state.outcome.text),
    };

    final compactResult = state is DictationDone || state is DictationFailed;

    return CallbackShortcuts(
      bindings: shortcuts,
      child: FocusScope(
        child: LayoutBuilder(
          builder: (context, box) {
            final micSize = compactResult
                ? 120.0
                : math.max(160.0, math.min(300.0, math.min(box.maxWidth - 48, box.maxHeight * 0.4)));
            final narrow = box.maxWidth < 480;
            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Space.gutter, 8, 8, 0),
                    child: Row(
                      children: [
                        Flexible(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: EngineChip(onTap: () => showEnginePicker(context)),
                          ),
                        ),
                        if (narrow)
                          IconButton(
                            tooltip: 'Edit style',
                            icon: const Icon(Icons.tune_rounded),
                            onPressed: () => showStyleEditor(context),
                          )
                        else
                          ?widget.trailing,
                      ],
                    ),
                  ),
                ),
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        children: [
                          if (compactResult) const SizedBox(height: Space.x3) else const Spacer(flex: 3),
                          Center(
                            child: MicButton(
                              state: state,
                              size: micSize,
                              autofocus: isLinux,
                              onTap: _toggle,
                              onHoldStart: _holdStart,
                              onHoldEnd: _holdEnd,
                            ),
                          ),
                          const SizedBox(height: Space.x2),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              status,
                              textAlign: TextAlign.center,
                              style: (compactResult ? text.titleMedium : text.titleLarge)?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                          if (state is DictationListening) ...[
                            const SizedBox(height: Space.x1),
                            ExcludeSemantics(child: Text(formatClock(state.elapsed), style: styles.timerLarge)),
                            Semantics(label: 'Elapsed ${formatClock(state.elapsed)}', child: const SizedBox.shrink()),
                            if (state.nearLimit) ...[const SizedBox(height: Space.x1), LimitChip(state: state)],
                          ],
                          if (state is DictationDone) ...[
                            const SizedBox(height: Space.x3),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                              child: _done(state.outcome),
                            ),
                          ],
                          if (state is DictationFailed) ...[
                            const SizedBox(height: Space.x3),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                              child: _ErrorBanner(failure: state, onRetry: () => _controller.retry(), onDismiss: _controller.reset),
                            ),
                          ],
                          if (compactResult) const SizedBox(height: Space.x3) else const Spacer(flex: 2),
                          if (state is! DictationListening && state is! DictationProcessing)
                            const Padding(
                              padding: EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.x2),
                              child: _PendingRecordings(),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: Space.x2),
                            child: StyleChips(onEdit: () => showStyleEditor(context), showEditButton: !narrow),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _done(DictationOutcome o) {
    final insert = ref.watch(lastInsertProvider);
    String? delivered;
    if (insert != null) {
      delivered = insert.delivered ? 'Typed into the focused app' : 'Copied to the clipboard. Paste with Ctrl+V.';
    }
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (o.fellBack) ...[
          NoticeBanner(message: fallbackNotice(o.fallbackReason!), tone: NoticeTone.info),
          const SizedBox(height: 12),
        ],
        ResultPanel(
          text: o.text,
          recordingId: o.recordingId,
          footer: delivered == null ? null : Text(delivered, style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
        ),
      ],
    );
  }
}

class _ErrorBanner extends ConsumerWidget {
  const _ErrorBanner({required this.failure, required this.onRetry, required this.onDismiss});

  final DictationFailed failure;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  /// The one button that fixes what went wrong.
  Widget? _fix(BuildContext context, WidgetRef ref) {
    final kind = failure.kind;
    if (failure.audioError == AudioSourceError.permissionDenied) {
      return FilledButton(
        onPressed: () async {
          final ok = await ref.read(platformServicesProvider).audio.requestPermission();
          if (ok) onDismiss();
        },
        child: const Text('Allow microphone'),
      );
    }
    if (kind == CleanupFailureKind.modelNotDownloaded) {
      return FilledButton(onPressed: () => showEnginePicker(context), child: const Text('Download model'));
    }
    if (kind == CleanupFailureKind.missingApiKey || kind == CleanupFailureKind.invalidApiKey) {
      return FilledButton(onPressed: () => showEnginePicker(context), child: const Text('Add API key'));
    }
    if (failure.canRetry) return FilledButton(onPressed: onRetry, child: const Text('Retry'));
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wait = failure.retryAfter;
    final extra = wait == null ? '' : ' Try again in ${wait.inSeconds < 1 ? 1 : wait.inSeconds} s.';
    final saved = failure.canRetry && !failure.message.contains('saved') ? ' Your recording is saved.' : '';
    return NoticeBanner(
      tone: NoticeTone.error,
      title: 'Could not finish',
      message: '${failure.message}$extra$saved',
      actions: [
        TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
        ?_fix(context, ref),
      ],
    );
  }
}

class _PendingRecordings extends ConsumerWidget {
  const _PendingRecordings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingRecordingsProvider).value ?? const <String>[];
    final state = ref.watch(dictationStateProvider).value;
    final failedId = state is DictationFailed ? state.recordingId : null;
    final ids = [for (final id in pending) if (id != failedId) id];
    if (ids.isEmpty) return const SizedBox.shrink();
    final controller = ref.read(dictationControllerProvider);
    return NoticeBanner(
      tone: NoticeTone.warning,
      icon: Icons.history_rounded,
      title: ids.length == 1 ? 'One recording was not cleaned up' : '${ids.length} recordings were not cleaned up',
      message: 'They are saved on this device. Retry to get the text.',
      actions: [
        for (var i = 0; i < ids.length; i++) ...[
          TextButton(
            onPressed: () async {
              await ref.read(recordingVaultProvider).delete(ids[i]);
              ref.invalidate(pendingRecordingsProvider);
            },
            child: Text(ids.length == 1 ? 'Discard' : 'Discard ${i + 1}'),
          ),
          FilledButton.tonal(
            onPressed: () async {
              ref.read(dictationOriginProvider.notifier).set(DictationOrigin.app);
              await controller.retry(ids[i]);
              ref.invalidate(pendingRecordingsProvider);
            },
            child: Text(ids.length == 1 ? 'Retry' : 'Retry ${i + 1}'),
          ),
        ],
      ],
    );
  }
}
