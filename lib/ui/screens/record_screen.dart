// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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
import '../widgets/limit_chip.dart';
import '../widgets/mic_button.dart';
import '../widgets/notice_banner.dart';
import '../widgets/result_card.dart';

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

class RecordScreen extends ConsumerStatefulWidget {
  const RecordScreen({super.key, this.compactHeader = false});

  /// Reserved for the two-pane layout.
  final bool compactHeader;

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

    final state = ref.watch(dictationStateProvider).value ?? _controller.state;
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

    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.escape): _cancel,
      if (state is DictationDone)
        const SingleActivator(LogicalKeyboardKey.keyC, control: true): () =>
            copyToClipboard(context, state.outcome.text),
    };

    return CallbackShortcuts(
      bindings: shortcuts,
      child: FocusScope(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Align(alignment: Alignment.center, child: EngineChip(onTap: () => context.go('/settings'))),
            const SizedBox(height: 24),
            Center(
              child: MicButton(
                state: state,
                size: 200,
                autofocus: isLinux,
                onTap: _toggle,
                onHoldStart: _holdStart,
                onHoldEnd: _holdEnd,
              ),
            ),
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: Text(
                status,
                textAlign: TextAlign.center,
                style: text.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            if (state is DictationListening) ...[
              Center(
                child: ExcludeSemantics(
                  child: Text(formatClock(state.elapsed), style: styles.timerLarge),
                ),
              ),
              Semantics(
                label: 'Elapsed ${formatClock(state.elapsed)}',
                child: const SizedBox.shrink(),
              ),
              if (state.nearLimit) ...[
                const SizedBox(height: 8),
                Center(child: LimitChip(state: state)),
              ],
            ],
            if (state is DictationDone) ..._done(state.outcome),
            if (state is DictationFailed) ...[
              const SizedBox(height: 16),
              _ErrorBanner(failure: state, onRetry: () => _controller.retry(), onDismiss: _controller.reset),
            ],
            const SizedBox(height: 16),
            if (state is! DictationListening && state is! DictationProcessing) const _PendingRecordings(),
          ],
        ),
      ),
    );
  }

  List<Widget> _done(DictationOutcome o) {
    final insert = ref.watch(lastInsertProvider);
    String? delivered;
    if (insert != null) {
      delivered = insert.delivered
          ? 'Typed into the focused app'
          : 'Copied to the clipboard. Paste with Ctrl+V.';
    }
    return [
      const SizedBox(height: 16),
      if (o.fellBack) ...[
        NoticeBanner(message: fallbackNotice(o.fallbackReason!), tone: NoticeTone.info),
        const SizedBox(height: 12),
      ],
      ResultCard(
        text: o.text,
        recordingId: o.recordingId,
        footer: delivered == null
            ? null
            : Text(delivered, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ),
    ];
  }
}

class _ErrorBanner extends ConsumerWidget {
  const _ErrorBanner({required this.failure, required this.onRetry, required this.onDismiss});

  final DictationFailed failure;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = <Widget>[];
    final audio = failure.audioError;
    final kind = failure.kind;

    if (audio == AudioSourceError.permissionDenied) {
      actions.add(FilledButton.tonal(
        onPressed: () async {
          final ok = await ref.read(platformServicesProvider).audio.requestPermission();
          if (ok) onDismiss();
        },
        child: const Text('Allow microphone'),
      ));
    }
    if (kind == CleanupFailureKind.modelNotDownloaded) {
      actions.add(FilledButton.tonal(onPressed: () => context.go('/settings'), child: const Text('Download model')));
    }
    if (kind == CleanupFailureKind.missingApiKey || kind == CleanupFailureKind.invalidApiKey) {
      actions.add(FilledButton.tonal(onPressed: () => context.go('/settings'), child: const Text('Add API key')));
    }
    if (failure.canRetry && (kind?.retryable ?? false)) {
      actions.add(FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')));
    } else if (failure.canRetry && actions.isEmpty) {
      actions.add(FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')));
    }
    actions.add(TextButton(onPressed: onDismiss, child: const Text('Dismiss')));

    final wait = failure.retryAfter;
    final extra = wait == null ? '' : ' Try again in ${wait.inSeconds < 1 ? 1 : wait.inSeconds} s.';
    final saved = failure.canRetry ? ' Your recording is saved.' : '';
    return NoticeBanner(
      tone: NoticeTone.error,
      title: 'Could not finish',
      message: '${failure.message}$extra${failure.message.contains('saved') ? '' : saved}',
      actions: actions,
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
