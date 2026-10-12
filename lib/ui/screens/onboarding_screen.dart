// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../core/audio/audio_source.dart';
import '../../core/audio/pcm.dart';
import '../../core/dictation/dictation_controller.dart';
import '../theme/app_theme.dart';
import '../util/platform_flags.dart';
import '../widgets/engine_picker.dart';
import '../widgets/mic_button.dart';
import '../widgets/style_chips.dart';
import 'settings/linux_section.dart';
import 'settings/misc_sections.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.initialStep = 0});

  final int initialStep;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static const _steps = 4;
  late int _step = widget.initialStep;

  Future<void> _finish() async {
    await ref.read(settingsProvider.notifier).update((s) => s.copyWith(onboarded: true));
    if (mounted) context.go('/');
  }

  void _next() {
    if (_step == _steps - 1) {
      _finish();
    } else {
      setState(() => _step++);
    }
  }

  void _back() => setState(() => _step--);

  @override
  Widget build(BuildContext context) {
    final isLinux = ref.watch(isLinuxProvider);
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;

    final (title, lead, body) = switch (_step) {
      0 => ('Let Ramble hear you', 'Speak naturally. Ramble turns the ramble into clean text.', const _MicStep()),
      1 => (
          'Pick how it cleans up',
          'You can switch any time from the record screen.',
          const EnginePicker(inset: 0),
        ),
      2 => ('Pick a tone', 'Casual, Professional, Texting or Notes. Change it with one tap later.', const _ToneStep()),
      _ => isLinux
          ? ('Dictate from anywhere', 'Bind a shortcut and Ramble types where your cursor is.', const LinuxSection())
          : ('Dictate in any app', 'The Ramble keyboard puts the microphone in every text field.', const AndroidSection()),
    };

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kContentWidth),
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.x3, Space.x2, Space.x1, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Semantics(
                            label: 'Step ${_step + 1} of $_steps',
                            child: Row(
                              children: [
                                for (var i = 0; i < _steps; i++) ...[
                                  if (i > 0) const SizedBox(width: 6),
                                  Expanded(
                                    child: AnimatedContainer(
                                      duration: Motion.of(context, Motion.medium),
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: i <= _step ? c.primary : c.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: Space.x1),
                        TextButton(onPressed: _finish, child: const Text('Skip')),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(Space.x3, Space.x4, Space.x3, Space.x2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(header: true, child: Text(title, style: t.headlineLarge)),
                          const SizedBox(height: Space.x1),
                          Text(lead, style: t.bodyLarge?.copyWith(color: c.onSurfaceVariant)),
                          const SizedBox(height: Space.x3),
                          body,
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.x3, Space.x1, Space.x3, Space.x2),
                    child: Row(
                      children: [
                        if (_step > 0) TextButton(onPressed: _back, child: const Text('Back')),
                        const Spacer(),
                        FilledButton(
                          onPressed: _next,
                          child: Text(_step == _steps - 1 ? 'Finish' : 'Next'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToneStep extends ConsumerWidget {
  const _ToneStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset = ref.watch(settingsProvider.select((s) => s.style.preset));
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Align(alignment: Alignment.centerLeft, child: StyleChips(centered: false, gutter: 0)),
        const SizedBox(height: Space.x2),
        Text('${preset.instruction}.', style: t.bodyLarge?.copyWith(color: c.onSurfaceVariant)),
      ],
    );
  }
}

class _MicStep extends ConsumerStatefulWidget {
  const _MicStep();

  @override
  ConsumerState<_MicStep> createState() => _MicStepState();
}

class _MicStepState extends ConsumerState<_MicStep> {
  bool? _granted;
  bool _testing = false;
  double _level = 0;
  String? _error;
  AudioCapture? _capture;
  StreamSubscription<dynamic>? _sub;

  @override
  void initState() {
    super.initState();
    ref.read(platformServicesProvider).audio.hasPermission().then((v) {
      if (mounted) setState(() => _granted = v);
    });
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
    final c = _capture;
    _capture = null;
    try {
      await c?.stop();
    } catch (_) {}
  }

  Future<void> _request() async {
    final ok = await ref.read(platformServicesProvider).audio.requestPermission();
    if (mounted) setState(() => _granted = ok);
  }

  Future<void> _test() async {
    if (_testing) {
      await _stop();
      if (mounted) setState(() => _testing = false);
      return;
    }
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      final capture = await ref.read(platformServicesProvider).audio.start();
      _capture = capture;
      _sub = capture.pcm.listen((b) {
        if (mounted) setState(() => _level = Pcm.level(b));
      });
      Timer(const Duration(seconds: 8), () async {
        if (_testing) {
          await _stop();
          if (mounted) setState(() => _testing = false);
        }
      });
    } on AudioSourceException catch (e) {
      setState(() {
        _testing = false;
        _error = switch (e.error) {
          AudioSourceError.permissionDenied => 'Microphone access is off.',
          AudioSourceError.deviceUnavailable => 'No microphone is available.',
          AudioSourceError.backendMissing => 'Audio capture is not available on this system.',
        };
      });
    } catch (_) {
      setState(() {
        _testing = false;
        _error = 'The microphone could not start.';
      });
    }
  }

  Future<void> _onTap() async {
    final isLinux = ref.read(isLinuxProvider);
    if (!isLinux && _granted != true) {
      await _request();
      return;
    }
    await _test();
  }

  @override
  Widget build(BuildContext context) {
    final isLinux = ref.watch(isLinuxProvider);
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final needsPermission = !isLinux && _granted != true;
    final caption = _testing
        ? 'Listening. Say something and watch the shape move.'
        : needsPermission
            ? 'Tap the microphone to allow access.'
            : _granted == true || isLinux
                ? 'Tap to test the microphone.'
                : 'Checking microphone access.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: MicButton(
            size: 176,
            onTap: _onTap,
            state: _testing
                ? DictationListening(
                    elapsed: Duration.zero,
                    level: _level,
                    limit: const Duration(minutes: 10),
                    warnBefore: const Duration(seconds: 30),
                  )
                : const DictationIdle(),
          ),
        ),
        const SizedBox(height: Space.x2),
        Semantics(
          liveRegion: true,
          child: Text(caption, textAlign: TextAlign.center, style: t.titleMedium?.copyWith(color: c.onSurfaceVariant)),
        ),
        if (_granted == true && !isLinux) ...[
          const SizedBox(height: Space.x1),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle_rounded, size: 18, color: c.primary),
              const SizedBox(width: 6),
              Text('Microphone allowed', style: t.labelLarge?.copyWith(color: c.onSurfaceVariant)),
            ],
          ),
        ],
        if (isLinux) ...[
          const SizedBox(height: Space.x1),
          Text(
            'Ramble Voice records through PipeWire. Your desktop may ask for permission the first time.',
            textAlign: TextAlign.center,
            style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: Space.x1),
          Text(_error!, textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(color: c.error)),
        ],
      ],
    );
  }
}
