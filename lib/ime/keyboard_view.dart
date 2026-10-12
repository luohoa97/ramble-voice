// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3ELoadingIndicator;
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../core/audio/audio_source.dart';
import '../core/cleanup/cleanup_engine.dart';
import '../core/dictation/dictation_controller.dart';
import '../platform/android/ime_bridge.dart';
import '../platform/platform_services.dart';
import '../ui/util/format.dart';
import '../ui/widgets/engine_chip.dart';
import '../ui/widgets/limit_chip.dart';
import '../ui/widgets/mic_button.dart';
import 'edit_panel.dart';
import 'edit_session.dart';
import 'ime_app.dart';
import 'key_style.dart';
import 'tone_bar.dart';
import 'qwerty_layer.dart';

/// How long the "Inserted / Undo" confirmation stays.
const _undoWindow = Duration(seconds: 8);

/// How long the done state shows before the mic returns to idle.
const _doneHold = Duration(milliseconds: 1400);

const _sideColumn = 72.0;

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

/// The keyboard panel: engine + status on top, hold-to-talk mic in the middle,
/// editing keys on the sides.
class KeyboardView extends ConsumerStatefulWidget {
  const KeyboardView({super.key});

  @override
  ConsumerState<KeyboardView> createState() => _KeyboardViewState();
}

class _KeyboardViewState extends ConsumerState<KeyboardView> {
  late final ImeBridge _bridge;
  final _subs = <StreamSubscription<Object?>>[];

  ImeInputInfo _info = const ImeInputInfo();
  bool _canSwitch = false;

  /// The QWERTY layer is showing instead of the dictation layer.
  bool _qwerty = false;

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
    unawaited(_refreshSwitch());
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

  Future<void> _refreshSwitch() async {
    final can = await _bridge.shouldOfferSwitch();
    if (mounted && can != _canSwitch) setState(() => _canSwitch = can);
  }

  Future<void> _onInputStarted(ImeInputInfo info) async {
    if (!mounted) return;
    _clearUndo();
    ref.read(imeEditProvider.notifier).reset();
    setState(() => _info = info);
    ref.read(currentPackageProvider.notifier).set(info.packageName);
    unawaited(_refreshSwitch());
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

  void _haptic(String kind) {
    if (!ref.read(settingsProvider).haptics) return;
    unawaited(ref.read(platformServicesProvider).haptic?.call(kind) ?? Future<void>.value());
  }

  void _onState(DictationState? prev, DictationState next) {
    switch (next) {
      case DictationListening() when prev is! DictationListening:
        _resetTimer?.cancel();
        _clearUndo();
        _haptic('start');
      case DictationProcessing() when prev is DictationListening:
        _haptic('stop');
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

    if (_qwerty) {
      return Material(
        color: scheme.surfaceContainer,
        child: QwertyLayer(onClose: () => setState(() => _qwerty = false)),
      );
    }

    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, 4, 8, bottom + 4),
        child: Column(
          children: [
            _TopBar(state: state, onEngineTap: () => _openApp(ImeRoutes.settings)),
            SizedBox(height: 44, child: ToneChips(onEdit: () => _openApp(ImeRoutes.style))),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: _sideColumn,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        if (_canSwitch)
                          _KeyButton(
                            icon: Icons.keyboard_alt_outlined,
                            label: 'Switch keyboard',
                            onPressed: () => unawaited(_bridge.switchToPreviousInputMethod()),
                          ),
                        AbcKey(onPressed: () => setState(() => _qwerty = true)),
                        _KeyButton(
                          icon: Icons.settings_outlined,
                          label: 'Open Ramble Voice settings',
                          onPressed: () => _openApp(ImeRoutes.settings),
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: edit.active ? const EditPanel() : _Center(
                    state: state,
                    info: _info,
                    undoText: _undoText,
                    onToggle: _toggle,
                    onHoldStart: _holdStart,
                    onHoldEnd: _holdEnd,
                    onUndo: _undo,
                    onFix: _openApp,
                    onDismiss: () => ref.read(dictationControllerProvider).reset(),
                    onRetry: () => unawaited(ref.read(dictationControllerProvider).retry()),
                  )),
                  SizedBox(
                    width: _sideColumn,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        EditKey(enabled: !_info.isPassword),
                        _RepeatKey(
                          icon: Icons.backspace_outlined,
                          label: 'Backspace',
                          onTrigger: () {
                            _clearUndo();
                            unawaited(_bridge.deleteBackward());
                          },
                        ),
                        _KeyButton(
                          icon: _enterIcon(_info.action),
                          label: _enterLabel(_info),
                          filled: true,
                          onPressed: () {
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

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.state, required this.onEngineTap});

  final DictationState state;
  final VoidCallback onEngineTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = state;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(child: Align(alignment: Alignment.centerLeft, child: EngineChip(onTap: onEngineTap))),
          if (s is DictationListening && s.nearLimit) ...[
            const SizedBox(width: 8),
            LimitChip(state: s),
          ] else
            const ToneHint(),
        ],
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
              final size = math.max(88.0, math.min(150.0, math.min(c.maxHeight, c.maxWidth) - 8));
              return Center(
                child: MicButton(
                  state: s,
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
          height: 48,
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
        DictationIdle(:final notice) => notice ??
            (info.isPassword ? 'Dictation is off in password fields' : 'Tap to talk, or hold'),
        DictationStarting() => 'Starting microphone',
        DictationListening(:final elapsed) => 'Listening  ${formatClock(elapsed)}',
        DictationProcessing(:final progress) => progress != null && progress.chunks > 1
            ? 'Cleaning up, part ${progress.chunk} of ${progress.chunks}'
            : 'Cleaning up',
        DictationDone() => 'Inserted',
        DictationFailed(:final message) => message,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = textFor(state, info);
    final style = theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final showUndo = undoText != null && (state is DictationIdle || state is DictationDone);

    return Semantics(
      liveRegion: true,
      container: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state is DictationProcessing) ...[
            M3ELoadingIndicator(size: 24, color: theme.colorScheme.primary, semanticLabel: 'Cleaning up'),
            const SizedBox(width: 8),
          ],
          if (state is DictationDone || showUndo) ...[
            Icon(Icons.check_circle_outline, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
          ],
          Flexible(child: Text(showUndo && state is DictationIdle ? 'Inserted' : text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (showUndo)
            TextButton.icon(
              onPressed: onUndo,
              icon: const Icon(Icons.undo, size: 18),
              label: const Text('Undo'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
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
          Icon(Icons.error_outline, color: scheme.error, size: 28),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
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
                ),
              if (failure.canRetry)
                FilledButton.tonal(
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
  final VoidCallback onPressed;
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
