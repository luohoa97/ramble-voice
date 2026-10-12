// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../core/audio/audio_source.dart';
import '../core/cleanup/cleanup_engine.dart';
import '../core/dictation/dictation_controller.dart';
import '../platform/android/ime_bridge.dart';
import '../platform/platform_services.dart';
import '../ui/util/format.dart';
import '../ui/widgets/mic_button.dart';
import 'edit_panel.dart';
import 'edit_session.dart';
import 'ime_app.dart';
import 'key_style.dart';
import 'tone_bar.dart';

/// How long the "Inserted / Undo" confirmation stays.
const _undoWindow = Duration(seconds: 5);

/// How long the done state shows before the mic returns to idle.
const _doneHold = Duration(milliseconds: 1400);

/// What the user can do about a failure from inside the keyboard.
class _Fix {
  const _Fix(this.label, this.route);
  final String label;
  final String route;
}

_Fix? _fixFor(DictationFailed f) {
  if (f.audioError == AudioSourceError.permissionDenied) {
    return const _Fix('Allow microphone in Ramble Voice', ImeRoutes.permissions);
  }
  return switch (f.kind) {
    CleanupFailureKind.modelNotDownloaded => const _Fix('Download a model', ImeRoutes.models),
    CleanupFailureKind.missingApiKey || CleanupFailureKind.invalidApiKey => const _Fix('Add Gemini key', ImeRoutes.settings),
    _ => null,
  };
}

/// The keyboard panel, modelled on a voice-typing panel: tone and engine on
/// top, the mic with one status line in the middle, keys along the bottom.
/// Typing happens in the user's own keyboard (ABC switches back to it).
class KeyboardView extends ConsumerStatefulWidget {
  const KeyboardView({super.key});

  @override
  ConsumerState<KeyboardView> createState() => _KeyboardViewState();
}

class _KeyboardViewState extends ConsumerState<KeyboardView> {
  late final ImeBridge _bridge;
  final _subs = <StreamSubscription<Object?>>[];

  ImeInputInfo _info = const ImeInputInfo();
  /// Text just typed into the field, while Undo is still offered.
  String? _undoText;
  Timer? _undoTimer;
  Timer? _resetTimer;

  @override
  void initState() {
    super.initState();
    _bridge = ref.read(imeBridgeProvider);
    _info = _bridge.current;
    // Providers may not change during initState.
    Future.microtask(() {
      if (mounted) ref.read(currentPackageProvider.notifier).set(_info.packageName);
    });
    _subs
      ..add(_bridge.inputStarted.listen(_onInputStarted))
      ..add(_bridge.inputFinished.listen((_) => _onInputFinished()));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _undoTimer?.cancel();
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _onInputStarted(ImeInputInfo info) async {
    if (!mounted) return;
    _clearUndo();
    ref.read(imeEditProvider.notifier).reset();
    setState(() => _info = info);
    ref.read(currentPackageProvider.notifier).set(info.packageName);
    // The app may have changed settings or downloaded a model since last time.
    final loaded = await ref.read(settingsStoreProvider).load();
    if (!mounted) return;
    if (jsonEncode(loaded.toJson()) != jsonEncode(ref.read(settingsProvider).toJson())) {
      await ref.read(settingsProvider.notifier).update((_) => loaded);
    }
    ref.invalidate(activeEngineReadinessProvider);
  }

  void _onInputFinished() {
    if (!mounted) return;
    _clearUndo();
    ref.read(imeEditProvider.notifier).reset();
    // Never throw a recording away: stop and clean it. If the field is gone
    // the inserter falls back to the clipboard, and it is saved in history.
    final c = ref.read(dictationControllerProvider);
    if (c.state is DictationListening) {
      unawaited(c.stop());
    }
  }

  void _clearUndo() {
    _undoTimer?.cancel();
    if (_undoText != null && mounted) setState(() => _undoText = null);
  }

  /// Haptics follow the Android system setting (View.performHapticFeedback),
  /// not an app switch.
  void _haptic(String kind) {
    unawaited(ref.read(platformServicesProvider).haptic?.call(kind) ?? Future<void>.value());
  }

  void _onState(DictationState? prev, DictationState next) {
    switch (next) {
      case DictationListening() when prev is! DictationListening:
        _resetTimer?.cancel();
        _clearUndo();
        _haptic('start');
      case DictationListening() when next.nearLimit && prev is DictationListening && !prev.nearLimit:
        _haptic('warn');
      case DictationProcessing() when prev is DictationListening:
        // Auto-stopped at the limit, or stopped by the user.
        _haptic(prev.remaining <= const Duration(seconds: 1) ? 'limit' : 'stop');
      case DictationDone(:final outcome):
        _haptic('done');
        final typed = ref.read(lastInsertProvider)?.method == InsertMethod.typed;
        if (typed && outcome.text.isNotEmpty) {
          setState(() => _undoText = outcome.text);
          _undoTimer?.cancel();
          _undoTimer = Timer(_undoWindow, _clearUndo);
        }
        _resetTimer?.cancel();
        _resetTimer = Timer(_doneHold, () {
          if (mounted) ref.read(dictationControllerProvider).reset();
        });
      case DictationFailed():
        _haptic('error');
      default:
    }
  }

  Future<void> _undo() async {
    final text = _undoText;
    if (text == null) return;
    _clearUndo();
    await _bridge.deleteBackward(count: text.runes.length);
  }

  void _toggle() {
    _resetTimer?.cancel();
    unawaited(ref.read(dictationControllerProvider).toggle());
  }

  void _holdStart() {
    _resetTimer?.cancel();
    final c = ref.read(dictationControllerProvider);
    if (!c.isBusy) unawaited(c.start());
  }

  void _holdEnd() {
    final c = ref.read(dictationControllerProvider);
    if (c.state is DictationListening) unawaited(c.stop());
  }

  void _openApp(String route) => unawaited(_bridge.openApp(route));

  void _tick() => _haptic('tick');

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<DictationState>>(dictationStateProvider, (prev, next) {
      final s = next.value;
      if (s != null) _onState(prev?.value, s);
    });
    final state = ref.watch(dictationStateProvider).value ?? const DictationIdle();
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    final edit = ref.watch(imeEditProvider);

    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 8, 12, bottom + 8),
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  ToneMenu(onEdit: () => _openApp(ImeRoutes.style), onTick: _tick),
                  const Spacer(),
                  Flexible(child: _EngineLabel(onTap: () => _openApp(ImeRoutes.settings), onTick: _tick)),
                  const SizedBox(width: 4),
                  _KeyButton(
                    icon: Icons.settings_outlined,
                    label: 'Ramble settings',
                    onPressed: () {
                      _tick();
                      _openApp(ImeRoutes.settings);
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 72,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (state is DictationListening) ...[
                          _KeyButton(
                            icon: state.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                            label: state.paused ? 'Resume recording' : 'Pause recording',
                            onPressed: () {
                              _tick();
                              final c = ref.read(dictationControllerProvider);
                              unawaited(state.paused ? c.resume() : c.pause());
                            },
                          ),
                          _KeyButton(
                            icon: Icons.delete_outline_rounded,
                            label: 'Discard recording',
                            onPressed: () {
                              _tick();
                              unawaited(ref.read(dictationControllerProvider).discard());
                            },
                          ),
                        ] else ...[
                          _TextKey(
                            label: 'ABC',
                            semantics: 'Switch to typing keyboard',
                            onPressed: () {
                              _tick();
                              unawaited(_bridge.switchToPreviousInputMethod());
                            },
                          ),
                          _KeyButton(
                            icon: Icons.edit_note_rounded,
                            label: 'Edit by voice',
                            onPressed: _info.isPassword
                                ? null
                                : () {
                                    _tick();
                                    unawaited(ref.read(imeEditProvider.notifier).begin());
                                  },
                          ),
                        ],
                      ],
                    ),
                  ),
                  Expanded(
                    child: edit.active
                      ? const EditPanel()
                      : _Center(
                          state: state,
                          info: _info,
                          undoText: _undoText,
                          onToggle: () {
                            _tick();
                            _toggle();
                          },
                          onHoldStart: _holdStart,
                          onHoldEnd: _holdEnd,
                          onUndo: () {
                            _tick();
                            final id = state is DictationIdle ? state.discardedId : null;
                            if (id != null) {
                              unawaited(ref.read(dictationControllerProvider).undoDiscard(id));
                            } else {
                              _undo();
                            }
                          },
                          onFix: (r) {
                            _tick();
                            _openApp(r);
                          },
                          onDismiss: () {
                            _tick();
                            ref.read(dictationControllerProvider).reset();
                          },
                          onRetry: () {
                            _tick();
                            unawaited(ref.read(dictationControllerProvider).retry());
                          },
                        ),
                  ),
                  SizedBox(
                    width: 72,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _RepeatKey(
                          icon: Icons.backspace_outlined,
                          label: 'Backspace',
                          onTrigger: () {
                            _tick();
                            _clearUndo();
                            unawaited(_bridge.deleteBackward());
                          },
                        ),
                        _KeyButton(
                          icon: _enterIcon(_info.action),
                          label: _enterLabel(_info),
                          filled: true,
                          onPressed: () {
                            _tick();
                            _clearUndo();
                            unawaited(_bridge.sendEnter());
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _enterIcon(ImeAction? a) => switch (a) {
      ImeAction.search => Icons.search,
      ImeAction.send => Icons.send,
      ImeAction.go || ImeAction.next => Icons.arrow_forward,
      ImeAction.done => Icons.check,
      ImeAction.previous => Icons.arrow_back,
      null => Icons.keyboard_return,
    };

String _enterLabel(ImeInputInfo info) {
  final custom = info.actionLabel;
  if (custom != null && custom.isNotEmpty) return custom;
  return switch (info.action) {
    ImeAction.search => 'Search',
    ImeAction.send => 'Send',
    ImeAction.go => 'Go',
    ImeAction.next => 'Next',
    ImeAction.done => 'Done',
    ImeAction.previous => 'Previous',
    null => 'Enter',
  };
}

/// "Gemma 4 E4B · GPU" or "Gemini 3.8 Flash": small, muted, no chrome.
class _EngineLabel extends ConsumerWidget {
  const _EngineLabel({required this.onTap, required this.onTick});

  final VoidCallback onTap;
  final VoidCallback onTick;

  static String text(EngineKind engine, String gemmaLabel, AsyncValue<EngineReadiness> r) {
    final detail = r.value is EngineReady ? (r.value! as EngineReady).detail : null;
    if (engine == EngineKind.onDevice) {
      final short = gemmaLabel.replaceFirst('Gemma 4 ', 'Gemma ');
      return short;
    }
    if (detail == null) return 'Gemini';
    final m = RegExp(r'^gemini-(\d+(?:\.\d+)?)-(pro|flash-lite|flash)').firstMatch(detail);
    if (m == null) return detail;
    final tier = switch (m.group(2)) {
      'pro' => 'Pro',
      'flash-lite' => 'Flash-Lite',
      _ => 'Flash',
    };
    return 'Gemini ${m.group(1)} $tier';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mq = MediaQuery.of(context);
    if (mq.size.width < 380 || mq.textScaler.scale(14) > 14 * 1.3) return const SizedBox.shrink();
    final settings = ref.watch(settingsProvider);
    final readiness = ref.watch(activeEngineReadinessProvider);
    final warn = readiness.value is EngineNotReady;
    final label = warn ? 'Not ready' : text(settings.engine, settings.gemmaVariant.label, readiness);
    final c = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        onTick();
        onTap();
      },
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: warn ? c.error : c.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

class _Center extends StatelessWidget {
  const _Center({
    required this.state,
    required this.info,
    required this.undoText,
    required this.onToggle,
    required this.onHoldStart,
    required this.onHoldEnd,
    required this.onUndo,
    required this.onFix,
    required this.onDismiss,
    required this.onRetry,
  });

  final DictationState state;
  final ImeInputInfo info;
  final String? undoText;
  final VoidCallback onToggle;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;
  final VoidCallback onUndo;
  final void Function(String route) onFix;
  final VoidCallback onDismiss;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = state;
    if (s is DictationFailed) {
      return _ErrorPanel(failure: s, onFix: onFix, onDismiss: onDismiss, onRetry: onRetry);
    }
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final size = math.max(88.0, math.min(104.0, c.maxHeight - 4));
              return Center(
                child: MicButton(
                  state: s is DictationListening && s.paused ? const DictationIdle() : s,
                  size: size,
                  enabled: !info.isPassword,
                  onTap: onToggle,
                  onHoldStart: onHoldStart,
                  onHoldEnd: onHoldEnd,
                ),
              );
            },
          ),
        ),
        SizedBox(
          height: 36,
          child: Center(child: _Status(state: s, info: info, undoText: undoText, onUndo: onUndo)),
        ),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.state, required this.info, required this.undoText, required this.onUndo});

  final DictationState state;
  final ImeInputInfo info;
  final String? undoText;
  final VoidCallback onUndo;

  static String textFor(DictationState s, ImeInputInfo info) => switch (s) {
        DictationIdle(:final discardedId) when discardedId != null => 'Discarded',
        DictationIdle(:final notice) => notice ??
            (info.isPassword ? 'Dictation is off in password fields' : 'Hold to talk, tap to toggle'),
        DictationStarting() => 'Starting microphone',
        DictationListening(:final elapsed, :final paused) when paused => 'Paused · ${formatClock(elapsed)}',
        DictationListening(:final elapsed, :final nearLimit, :final remaining) =>
          nearLimit ? '${formatClock(remaining)} left' : 'Listening ${formatClock(elapsed)}',
        DictationProcessing(:final progress) => progress != null && progress.chunks > 1
            ? 'Cleaning up, part ${progress.chunk} of ${progress.chunks}'
            : 'Cleaning up',
        DictationDone() => 'Inserted',
        DictationFailed(:final message) => message,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final discarded = state is DictationIdle && (state as DictationIdle).discardedId != null;
    final showUndo = discarded || (undoText != null && (state is DictationIdle || state is DictationDone));
    final text = discarded ? 'Discarded' : (showUndo ? 'Inserted' : textFor(state, info));

    return Semantics(
      liveRegion: true,
      container: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (showUndo) ...[
            Text(' · ', style: style),
            TextButton(
              onPressed: onUndo,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                foregroundColor: theme.colorScheme.primary,
              ),
              child: const Text('Undo'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.failure, required this.onFix, required this.onDismiss, required this.onRetry});

  final DictationFailed failure;
  final void Function(String route) onFix;
  final VoidCallback onDismiss;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fix = _fixFor(failure);
    final message = failure.audioError == AudioSourceError.permissionDenied
        ? 'Microphone access is off. Ramble Voice needs it to hear you.'
        : failure.message;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              if (fix != null)
                FilledButton(
                  onPressed: () => onFix(fix.route),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: Text(fix.label),
                )
              else if (failure.canRetry)
                FilledButton(
                  onPressed: onRetry,
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: const Text('Try again'),
                ),
              TextButton(
                onPressed: onDismiss,
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                child: const Text('Dismiss'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A 56 dp key. The tooltip doubles as the accessibility label.
class _KeyButton extends StatelessWidget {
  const _KeyButton({required this.icon, required this.label, required this.onPressed, this.filled = false});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return filled
        ? IconButton.filled(
            onPressed: onPressed,
            icon: Icon(icon),
            tooltip: label,
            style: const ButtonStyle(
              fixedSize: WidgetStatePropertyAll(Size(56, 56)),
              minimumSize: WidgetStatePropertyAll(Size(56, 56)),
            ),
          )
        : IconButton.filledTonal(onPressed: onPressed, icon: Icon(icon), tooltip: label, style: keyStyle(context));
  }
}

/// A key that shows text, like Gboard's "ABC".
class _TextKey extends StatelessWidget {
  const _TextKey({required this.label, required this.semantics, required this.onPressed});

  final String label;
  final String semantics;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semantics,
      excludeSemantics: true,
      onTap: onPressed,
      child: FilledButton.tonal(
        onPressed: onPressed,
        style: keyStyle(context).copyWith(
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          textStyle: WidgetStatePropertyAll(Theme.of(context).textTheme.labelLarge),
        ),
        child: Text(label),
      ),
    );
  }
}

/// A key that fires once on press and then repeats while held.
class _RepeatKey extends StatefulWidget {
  const _RepeatKey({required this.icon, required this.label, required this.onTrigger});

  final IconData icon;
  final String label;
  final VoidCallback onTrigger;

  @override
  State<_RepeatKey> createState() => _RepeatKeyState();
}

class _RepeatKeyState extends State<_RepeatKey> {
  Timer? _delay;
  Timer? _repeat;

  void _down() {
    widget.onTrigger();
    _delay = Timer(const Duration(milliseconds: 400), () {
      _repeat = Timer.periodic(const Duration(milliseconds: 55), (_) => widget.onTrigger());
    });
  }

  void _up() {
    _delay?.cancel();
    _repeat?.cancel();
    _delay = null;
    _repeat = null;
  }

  @override
  void dispose() {
    _up();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      onTap: widget.onTrigger,
      excludeSemantics: true,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _down(),
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: SizedBox(
          width: 56,
          height: 56,
          child: DecoratedBox(
            decoration: BoxDecoration(color: keyFill(context), shape: BoxShape.circle),
            child: Icon(widget.icon, color: keyForeground(context)),
          ),
        ),
      ),
    );
  }
}
