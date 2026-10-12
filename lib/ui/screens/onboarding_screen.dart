// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../core/audio/audio_source.dart';
import '../../core/audio/pcm.dart';
import '../../core/cleanup/cleanup_engine.dart';
import '../theme/app_theme.dart';
import '../util/platform_flags.dart';
import '../widgets/level_meter.dart';
import 'settings/gemini_section.dart';
import 'settings/linux_section.dart';
import 'settings/misc_sections.dart';
import 'settings/model_section.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static const _steps = 4;
  int _step = 0;

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
    final engine = ref.watch(settingsProvider.select((s) => s.engine));
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;

    final (title, body) = switch (_step) {
      0 => (
          'Microphone',
          const _MicStep(),
        ),
      1 => ('Choose an engine', const _EngineStep()),
      2 => engine == EngineKind.onDevice
          ? ('Download the model', const ModelSection())
          : ('Set up Gemini', const GeminiSection()),
      _ => isLinux
          ? ('Shortcut and typing', const LinuxSection())
          : ('Ramble keyboard', const AndroidSection()),
    };

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Semantics(
                            label: 'Step ${_step + 1} of $_steps',
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(value: (_step + 1) / _steps, minHeight: 6),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        TextButton(onPressed: _finish, child: const Text('Skip setup')),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Step ${_step + 1} of $_steps', style: t.labelLarge?.copyWith(color: c.onSurfaceVariant)),
                          const SizedBox(height: 4),
                          Semantics(header: true, child: Text(title, style: t.headlineMedium)),
                          const SizedBox(height: 16),
                          body,
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Row(
                      children: [
                        if (_step > 0) OutlinedButton(onPressed: _back, child: const Text('Back')),
                        const Spacer(),
                        TextButton(
                          onPressed: _next,
                          child: Text(_step == _steps - 1 ? 'Skip' : 'Skip step'),
                        ),
                        const SizedBox(width: 8),
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

  @override
  Widget build(BuildContext context) {
    final isLinux = ref.watch(isLinuxProvider);
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isLinux
              ? 'Ramble Voice records through PipeWire. Your desktop may ask for permission the first time. Test the microphone and watch the level move as you speak.'
              : 'Ramble Voice needs the microphone to hear you. Audio stays on this device unless you choose Gemini cloud.',
          style: t.bodyLarge,
        ),
        const SizedBox(height: 16),
        if (!isLinux)
          Row(
            children: [
              FilledButton.icon(
                onPressed: _granted == true ? null : _request,
                icon: Icon(_granted == true ? Icons.check_rounded : Icons.mic_rounded),
                label: Text(_granted == true ? 'Microphone allowed' : 'Allow microphone'),
              ),
            ],
          ),
        if (isLinux || _granted == true) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(onPressed: _test, child: Text(_testing ? 'Stop test' : 'Test microphone')),
              const SizedBox(width: 16),
              if (_testing) LevelMeter(level: _level),
            ],
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: t.bodyMedium?.copyWith(color: c.error)),
        ],
      ],
    );
  }
}

class _EngineStep extends ConsumerWidget {
  const _EngineStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(settingsProvider.select((s) => s.engine));
    return Column(
      children: [
        _EngineCard(
          selected: engine == EngineKind.onDevice,
          icon: Icons.memory_rounded,
          title: engineTaglines[EngineKind.onDevice]!,
          body: 'Runs Gemma 4 on this device. Needs a one-time model download of 2.6 to 3.7 GB.',
          onTap: () => ref.read(settingsProvider.notifier).update((s) => s.copyWith(engine: EngineKind.onDevice)),
        ),
        const SizedBox(height: 12),
        _EngineCard(
          selected: engine == EngineKind.gemini,
          icon: Icons.cloud_outlined,
          title: engineTaglines[EngineKind.gemini]!,
          body: 'Uses your own Gemini API key. Audio is sent to Google for each dictation.',
          onTap: () => ref.read(settingsProvider.notifier).update((s) => s.copyWith(engine: EngineKind.gemini)),
        ),
      ],
    );
  }
}

class _EngineCard extends StatelessWidget {
  const _EngineCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: title,
      hint: body,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? c.secondaryContainer : c.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Shapes.extraLarge),
          side: BorderSide(color: selected ? c.primary : c.outlineVariant, width: selected ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Icon(icon, size: 32, color: selected ? c.onSecondaryContainer : c.onSurfaceVariant),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: t.titleMedium),
                      const SizedBox(height: 4),
                      Text(body, style: t.bodyMedium),
                    ],
                  ),
                ),
                if (selected) Icon(Icons.check_circle_rounded, color: c.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
