// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3ELoadingIndicator, M3ESpring;
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/dictation/dictation_controller.dart';
import '../theme/app_theme.dart';

/// The hero control. Shape morphs between states with a spring:
/// idle = 9-sided cookie, listening = sunny burst that follows input level,
/// processing = circle holding the M3 Expressive loading indicator.
class MicButton extends StatefulWidget {
  const MicButton({
    super.key,
    required this.state,
    required this.onTap,
    this.onHoldStart,
    this.onHoldEnd,
    this.size = 160,
    this.enabled = true,
    this.autofocus = false,
  });

  final DictationState state;

  /// Tap-to-toggle.
  final VoidCallback onTap;

  /// Long-press start (hold-to-talk).
  final VoidCallback? onHoldStart;

  /// Release after a hold.
  final VoidCallback? onHoldEnd;
  final double size;
  final bool enabled;

  /// Takes keyboard focus on first build (desktop home screen).
  final bool autofocus;

  static String labelFor(DictationState s) => switch (s) {
        DictationStarting() => 'Starting microphone',
        DictationListening() => 'Stop and clean up',
        DictationProcessing() => 'Cleaning up',
        DictationIdle() || DictationDone() || DictationFailed() => 'Start dictation',
      };

  static String hintFor(DictationState s) => switch (s) {
        DictationListening() => 'Stops recording and cleans up the text',
        DictationProcessing() || DictationStarting() => '',
        _ => 'Starts recording. Touch and hold to talk while held',
      };

  @override
  State<MicButton> createState() => _MicButtonState();
}

enum _Visual { idle, listening, processing, done, error }

_Visual _visualOf(DictationState s) => switch (s) {
      DictationIdle() || DictationStarting() => _Visual.idle,
      DictationListening() => _Visual.listening,
      DictationProcessing() => _Visual.processing,
      DictationDone() => _Visual.done,
      DictationFailed() => _Visual.error,
    };

RoundedPolygon _polygonOf(_Visual v) => switch (v) {
      _Visual.idle => MaterialShapes.cookie9Sided,
      _Visual.listening => MaterialShapes.sunny,
      _Visual.processing => MaterialShapes.circle,
      _Visual.done => MaterialShapes.cookie9Sided,
      _Visual.error => MaterialShapes.pentagon,
    };

final _morphCache = <(RoundedPolygon, RoundedPolygon), Morph>{};
Morph _morph(RoundedPolygon a, RoundedPolygon b) => _morphCache.putIfAbsent((a, b), () => Morph(a, b));

/// Damped spring toward 1, mass 1.
class _Spring {
  _Spring(M3ESpring s)
      : _k = s.stiffness,
        _c = 2 * s.damping * math.sqrt(s.stiffness);
  final double _k;
  final double _c;
  double x = 1;
  double v = 0;

  void reset() {
    x = 0;
    v = 0;
  }

  bool get settled => (x - 1).abs() < 0.0005 && v.abs() < 0.001;

  void step(double dt) {
    var left = dt;
    while (left > 0) {
      final h = math.min(left, 1 / 240);
      v += (-_k * (x - 1) - _c * v) * h;
      x += v * h;
      left -= h;
    }
    if (settled) {
      x = 1;
      v = 0;
    }
  }
}

class _MicButtonState extends State<MicButton> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _repaint = ValueNotifier<int>(0);
  final _spring = _Spring(Motion.spatial);
  Duration _last = Duration.zero;

  late _Visual _visual;
  late RoundedPolygon _from;
  late RoundedPolygon _to;

  double _level = 0;
  double _angle = 0;
  bool _focused = false;
  bool _holding = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _visual = _visualOf(widget.state);
    _from = _to = _polygonOf(_visual);
    _ticker = createTicker(_onTick);
    _syncTicker();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _spring.x = 1;
  }

  @override
  void didUpdateWidget(MicButton old) {
    super.didUpdateWidget(old);
    final v = _visualOf(widget.state);
    if (v != _visual) {
      _visual = v;
      final next = _polygonOf(v);
      if (next != _to) {
        _from = _spring.x > 0.5 ? _to : _from;
        _to = next;
        _spring.reset();
        if (_reduceMotion) _spring.x = 1;
      }
    }
    _syncTicker();
  }

  double get _targetLevel {
    final s = widget.state;
    if (s is! DictationListening) return 0;
    return math.sqrt(s.level.clamp(0.0, 1.0)).clamp(0.0, 1.0);
  }

  void _syncTicker() {
    final need = !_spring.settled ||
        (_level - _targetLevel).abs() > 0.002 ||
        (_visual == _Visual.listening && !_reduceMotion) ||
        _angle.abs() > 0.01;
    if (need && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!need && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration now) {
    final dt = _last == Duration.zero ? 1 / 60 : math.min((now - _last).inMicroseconds / 1e6, 0.05);
    _last = now;
    if (_reduceMotion) {
      _spring.x = 1;
      _spring.v = 0;
    } else {
      _spring.step(dt);
    }
    final target = _targetLevel;
    final tau = target > _level ? 0.04 : 0.18;
    _level += (target - _level) * (1 - math.exp(-dt / tau));
    if (_visual == _Visual.listening && !_reduceMotion) {
      _angle += dt * 0.5;
      if (_angle > math.pi * 2) _angle -= math.pi * 2;
    } else {
      var a = _angle;
      if (a > math.pi) a -= math.pi * 2;
      a *= math.exp(-dt * 6);
      _angle = a.abs() < 0.005 ? 0 : a;
    }
    _repaint.value++;
    if (!(!_spring.settled ||
        (_level - target).abs() > 0.002 ||
        (_visual == _Visual.listening && !_reduceMotion) ||
        _angle != 0)) {
      _level = target;
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  bool get _interactive => widget.enabled && widget.state is! DictationProcessing && widget.state is! DictationStarting;

  void _activate() {
    if (_interactive) widget.onTap();
  }

  void _holdStart() {
    if (!_interactive || widget.onHoldStart == null) return;
    if (widget.state is DictationListening) return;
    _holding = true;
    widget.onHoldStart!();
  }

  void _holdEnd() {
    if (!_holding) return;
    _holding = false;
    widget.onHoldEnd?.call();
  }

  ({Color fill, Color on}) _colors(ColorScheme c) => switch (_visual) {
        _Visual.idle => (fill: c.primaryContainer, on: c.onPrimaryContainer),
        _Visual.listening => (fill: c.primary, on: c.onPrimary),
        _Visual.processing => (fill: c.secondaryContainer, on: c.onSecondaryContainer),
        _Visual.done => (fill: c.tertiaryContainer, on: c.onTertiaryContainer),
        _Visual.error => (fill: c.errorContainer, on: c.onErrorContainer),
      };

  IconData get _icon => switch (_visual) {
        _Visual.idle => Icons.mic_rounded,
        _Visual.listening => Icons.stop_rounded,
        _Visual.processing => Icons.hourglass_empty_rounded,
        _Visual.done => Icons.check_rounded,
        _Visual.error => Icons.mic_off_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = _colors(scheme);
    final label = MicButton.labelFor(widget.state);
    final hint = MicButton.hintFor(widget.state);
    final size = widget.size;
    final dim = !widget.enabled;

    Widget center;
    if (_visual == _Visual.processing && !_reduceMotion) {
      center = M3ELoadingIndicator(
        key: const ValueKey('loading'),
        size: size * 0.5,
        color: colors.on,
        semanticLabel: 'Cleaning up',
      );
    } else {
      center = Icon(_icon, key: ValueKey(_icon), size: size * 0.32, color: colors.on);
    }

    final body = TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: colors.fill),
      duration: Motion.of(context, Motion.short),
      builder: (context, fill, _) => CustomPaint(
        size: Size.square(size),
        painter: _MicPainter(
          owner: this,
          fill: fill ?? colors.fill,
          ring: scheme.primary,
          focus: scheme.tertiary,
          repaint: _repaint,
          focused: _focused,
        ),
        child: SizedBox.square(
          dimension: size,
          child: Center(
            child: AnimatedSwitcher(
              duration: Motion.of(context, Motion.short),
              child: center,
            ),
          ),
        ),
      ),
    );

    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: _interactive,
        label: label,
        hint: hint.isEmpty ? null : hint,
        onTap: _interactive ? _activate : null,
        excludeSemantics: true,
        child: FocusableActionDetector(
          enabled: widget.enabled,
          autofocus: widget.autofocus,
          mouseCursor: _interactive ? SystemMouseCursors.click : SystemMouseCursors.basic,
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
              _activate();
              return null;
            }),
          },
          onShowFocusHighlight: (v) {
            _focused = v;
            _repaint.value++;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _activate,
            onLongPressStart: (_) => _holdStart(),
            onLongPressEnd: (_) => _holdEnd(),
            onLongPressCancel: _holdEnd,
            child: Opacity(opacity: dim ? 0.5 : 1, child: SizedBox.square(dimension: size, child: body)),
          ),
        ),
      ),
    );
  }
}

class _MicPainter extends CustomPainter {
  _MicPainter({
    required this.owner,
    required this.fill,
    required this.ring,
    required this.focus,
    required this.focused,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final _MicButtonState owner;
  final Color fill;
  final Color ring;
  final Color focus;
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = size.center(Offset.zero);
    final level = owner._level;
    final base = s * 0.74;

    if (owner._visual == _Visual.listening || level > 0.01) {
      final r = (base / 2) * (1.08 + 0.3 * level);
      canvas.drawCircle(c, r, Paint()..color = ring.withValues(alpha: 0.10 + 0.12 * level));
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = ring.withValues(alpha: 0.25 + 0.4 * level),
      );
    }

    final morph = _morph(owner._from, owner._to);
    final path = morph.toPath(progress: owner._spring.x, rotationPivotX: 0.5, rotationPivotY: 0.5);
    final scale = base * (1 + 0.1 * level);
    canvas
      ..save()
      ..translate(c.dx, c.dy)
      ..rotate(owner._angle)
      ..scale(scale)
      ..translate(-0.5, -0.5)
      ..drawPath(path, Paint()..color = fill..isAntiAlias = true)
      ..restore();

    if (focused) {
      canvas.drawCircle(
        c,
        s / 2 - 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = focus,
      );
    }
  }

  @override
  bool shouldRepaint(_MicPainter old) => old.fill != fill || old.ring != ring || old.focus != focus || old.focused != focused;
}
