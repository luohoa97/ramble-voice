// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../platform/android/ime_bridge.dart';
import 'ime_app.dart';
import 'key_style.dart';
import 'qwerty_layout.dart';

/// A compact QWERTY layer for quick fixes without leaving the keyboard. Every
/// key commits text straight to the field. The dictation layer stays the
/// default; [onClose] returns to it.
class QwertyLayer extends ConsumerStatefulWidget {
  const QwertyLayer({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<QwertyLayer> createState() => _QwertyLayerState();
}

class _QwertyLayerState extends ConsumerState<QwertyLayer> {
  late final ImeBridge _bridge = ref.read(imeBridgeProvider);
  QwertyPage _page = QwertyPage.letters;
  ShiftState _shift = ShiftState.off;
  DateTime? _lastShiftTap;

  void _tick() {
    if (!ref.read(settingsProvider).haptics) return;
    unawaited(ref.read(platformServicesProvider).haptic?.call('tick') ?? Future<void>.value());
  }

  void _type(String key) {
    _tick();
    final shifted = _page == QwertyPage.letters && _shift != ShiftState.off;
    unawaited(_bridge.commitText(shifted ? key.toUpperCase() : key));
    if (_shift == ShiftState.once) setState(() => _shift = ShiftState.off);
  }

  void _onShift() {
    _tick();
    final now = DateTime.now();
    final doubleTap = _lastShiftTap != null && now.difference(_lastShiftTap!) < const Duration(milliseconds: 400);
    _lastShiftTap = now;
    setState(() => _shift = nextShift(_shift, doubleTap: doubleTap));
  }

  void _backspace() {
    _tick();
    unawaited(_bridge.deleteBackward());
  }

  void _enter() {
    _tick();
    unawaited(_bridge.sendEnter());
  }

  @override
  Widget build(BuildContext context) {
    final info = _bridge.current;
    final rows = qwertyRows(_page);
    final letters = _page == QwertyPage.letters;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;

    Widget row(List<Widget> keys) => Expanded(child: Row(children: keys));

    return Padding(
      padding: EdgeInsets.fromLTRB(4, 4, 4, bottom + 4),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++)
            row([
              if (i == 2 && letters)
                _Key.action(
                  icon: _shift == ShiftState.caps ? Icons.keyboard_capslock : Icons.keyboard_arrow_up,
                  label: _shift == ShiftState.off ? 'Shift' : (_shift == ShiftState.once ? 'Shift on' : 'Caps lock on'),
                  flex: 15,
                  selected: _shift != ShiftState.off,
                  onTap: _onShift,
                ),
              if (i == 2 && !letters)
                _Key.action(
                  icon: null,
                  text: _page == QwertyPage.symbols ? '=\\<' : '?123',
                  label: _page == QwertyPage.symbols ? 'More symbols' : 'Symbols',
                  flex: 15,
                  onTap: () => setState(() => _page = _page == QwertyPage.symbols ? QwertyPage.moreSymbols : QwertyPage.symbols),
                ),
              for (final k in rows[i])
                _Key.char(
                  text: letters && _shift != ShiftState.off ? k.toUpperCase() : k,
                  flex: 10,
                  onTap: () => _type(k),
                ),
              if (i == 2)
                _Key.action(
                  icon: Icons.backspace_outlined,
                  label: 'Backspace',
                  flex: 15,
                  repeat: true,
                  onTap: _backspace,
                ),
            ]),
          row([
            _Key.action(
              icon: null,
              text: letters ? '?123' : 'ABC',
              label: letters ? 'Symbols' : 'Letters',
              flex: 15,
              onTap: () => setState(() {
                _page = letters ? QwertyPage.symbols : QwertyPage.letters;
                _shift = ShiftState.off;
              }),
            ),
            _Key.action(
              icon: Icons.mic_none,
              label: 'Back to dictation',
              flex: 12,
              onTap: () {
                _tick();
                widget.onClose();
              },
            ),
            _Key.char(text: ',', flex: 10, onTap: () => _type(',')),
            _Key.char(text: '', label: 'Space', flex: 40, onTap: () => _type(' ')),
            _Key.char(text: '.', flex: 10, onTap: () => _type('.')),
            _Key.action(
              icon: _enterIcon(info.action),
              label: 'Enter',
              flex: 15,
              filled: true,
              onTap: _enter,
            ),
          ]),
        ],
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

/// One key. Fires on pointer down for a responsive feel; [repeat] keys keep
/// firing while held.
class _Key extends StatefulWidget {
  const _Key._({
    required this.flex,
    required this.onTap,
    required this.label,
    this.text,
    this.icon,
    this.action = false,
    this.filled = false,
    this.selected = false,
    this.repeat = false,
  });

  factory _Key.char({required String text, required int flex, required VoidCallback onTap, String? label}) =>
      _Key._(flex: flex, onTap: onTap, text: text, label: label ?? text);

  factory _Key.action({
    required IconData? icon,
    required String label,
    required int flex,
    required VoidCallback onTap,
    String? text,
    bool filled = false,
    bool selected = false,
    bool repeat = false,
  }) =>
      _Key._(
        flex: flex,
        onTap: onTap,
        label: label,
        icon: icon,
        text: text,
        action: true,
        filled: filled,
        selected: selected,
        repeat: repeat,
      );

  final int flex;
  final VoidCallback onTap;
  final String label;
  final String? text;
  final IconData? icon;
  final bool action;
  final bool filled;
  final bool selected;
  final bool repeat;

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  Timer? _delay;
  Timer? _repeat;
  bool _down = false;

  void _press() {
    setState(() => _down = true);
    widget.onTap();
    if (widget.repeat) {
      _delay = Timer(const Duration(milliseconds: 400), () {
        _repeat = Timer.periodic(const Duration(milliseconds: 55), (_) => widget.onTap());
      });
    }
  }

  void _release() {
    _delay?.cancel();
    _repeat?.cancel();
    _delay = _repeat = null;
    if (_down && mounted) setState(() => _down = false);
  }

  @override
  void dispose() {
    _delay?.cancel();
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final (Color bg, Color fg) = widget.filled
        ? (scheme.primary, scheme.onPrimary)
        : widget.selected
            ? (scheme.primaryContainer, scheme.onPrimaryContainer)
            : widget.action
                ? (scheme.secondaryContainer, scheme.onSecondaryContainer)
                : (scheme.surfaceContainerHighest, scheme.onSurface);
    final pressed = _down ? Color.alphaBlend(fg.withValues(alpha: 0.16), bg) : bg;

    return Expanded(
      flex: widget.flex,
      child: Semantics(
        button: true,
        label: widget.label,
        onTap: widget.onTap,
        excludeSemantics: true,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _press(),
          onPointerUp: (_) => _release(),
          onPointerCancel: (_) => _release(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.all(2.5),
              child: DecoratedBox(
                decoration: BoxDecoration(color: pressed, borderRadius: BorderRadius.circular(10)),
                child: Center(
                  child: widget.icon != null
                      ? Icon(widget.icon, color: fg)
                      : Text(
                          widget.text ?? '',
                          style: (widget.action ? theme.textTheme.labelLarge : theme.textTheme.titleLarge)
                              ?.copyWith(color: fg),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The "ABC" key on the dictation layer that opens [QwertyLayer]. 56 dp.
class AbcKey extends StatelessWidget {
  const AbcKey({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      onPressed: onPressed,
      tooltip: 'Type with keys',
      icon: Text('ABC', style: Theme.of(context).textTheme.labelLarge),
      style: keyStyle(context),
    );
  }
}
