// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../platform/android/android_system.dart';
import '../theme/app_theme.dart';
import '../util/hotkey_state.dart';
import '../util/platform_flags.dart';
import 'onboarding/setup_status.dart';
import 'onboarding/setup_steps.dart';

/// The guided setup. Each step has one title, a sentence or two, one primary
/// action and a live status; a step that the device can check moves on by
/// itself once it is done. Opened on first run and again from Settings.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.initialStep = 0});

  final int initialStep;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> with WidgetsBindingObserver {
  late int _step = widget.initialStep;
  Timer? _poll;
  Timer? _advance;
  var _micAsked = false;

  List<String> get _steps => setupStepsFor(android: ref.read(isAndroidProvider));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Reopened part-way (the app was closed, or the system restarted it):
    // continue at the first step not done yet instead of starting over.
    final done = ref.read(settingsProvider).completedSetup;
    if (widget.initialStep == 0 && done.isNotEmpty) {
      final next = _steps.indexWhere((s) => !done.contains(s));
      if (next > 0) _step = next;
    }
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => ref.invalidate(setupStatusProvider));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _advance?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.invalidate(setupStatusProvider);
  }

  Future<void> _complete(String id) {
    if (ref.read(settingsProvider).completedSetup.contains(id)) return Future.value();
    return ref.read(settingsProvider.notifier).update((s) => s.copyWith(completedSetup: {...s.completedSetup, id}));
  }

  Future<void> _finish() async {
    await ref.read(settingsProvider.notifier).update((s) => s.copyWith(
          onboarded: true,
          completedSetup: {...s.completedSetup, _steps.last},
        ));
    if (mounted) context.go('/');
  }

  /// Leaving early keeps the unfinished steps for the banner.
  Future<void> _skipAll() async {
    await ref.read(settingsProvider.notifier).update((s) => s.copyWith(onboarded: true));
    if (mounted) context.go('/');
  }

  void _next() {
    _advance?.cancel();
    final id = _steps[_step];
    unawaited(_complete(id));
    if (_step >= _steps.length - 1) {
      unawaited(_finish());
    } else {
      setState(() => _step++);
    }
  }

  void _back() {
    _advance?.cancel();
    setState(() => _step--);
  }

  void _onStatus(SetupStatus? prev, SetupStatus next) {
    final id = _steps[_step];
    for (final s in _steps) {
      if (detected(s, next)) unawaited(_complete(s));
    }
    if (detected(id, next) && !detected(id, prev) && prev != null) {
      _advance?.cancel();
      _advance = Timer(const Duration(milliseconds: 900), () {
        if (mounted && _steps[_step] == id) _next();
      });
    }
  }

  Future<void> _requestMic() async {
    final audio = ref.read(platformServicesProvider).audio;
    final ok = await audio.requestPermission();
    _micAsked = true;
    if (!ok && mounted) await ref.read(androidSystemProvider).openAppDetails();
    ref.invalidate(setupStatusProvider);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<SetupStatus>>(setupStatusProvider, (prev, next) {
      final v = next.value;
      if (v != null) _onStatus(prev?.value, v);
    });
    final status = ref.watch(setupStatusProvider).value;
    final steps = _steps;
    final id = steps[_step];
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final android = ref.watch(isAndroidProvider);
    final system = ref.read(androidSystemProvider);
    final done = detected(id, status);
    final last = _step == steps.length - 1;

    final (String title, String lead, Widget body) = switch (id) {
      'welcome' => ('Speak messily. Get clean text.', 'Ramble turns what you say into clean text, in any app.', const WelcomeStepBody()),
      'mic' => ('Let Ramble hear you', 'Ramble needs the microphone. Audio stays on this device unless you choose Gemini.', MicStepBody(status: status, onTapMic: _requestMic)),
      'engine' => ('Pick how it cleans up', 'On-device is private and free. Gemini is smarter and needs a key.', EngineStepBody(status: status)),
      'keyboard' => ('Turn on the Ramble keyboard', 'It puts the microphone in every text field.', KeyboardStepBody(status: status)),
      'bubble' => ('Turn on the floating mic', 'A small mic that floats over other apps, so you can dictate next to Gboard.', BubbleStepBody(status: status)),
      'try' => ('Try it', 'Dictate into this box and watch it type for you.', TryStepBody(onTyped: () => _complete('try'))),
      'tips' => ('Three quick tips', 'You can change these any time.', const TipsStepBody()),
      'hotkey' => ('Set your shortcut', 'Press it anywhere to start dictating.', HotkeyStepBody(status: status)),
      'typing' => ('Let Ramble type for you', 'Ramble types the cleaned text into the app you are using.', const TypingStepBody()),
      'tray' => ('Ramble stays in the tray', 'Close the window and it keeps listening for your shortcut.', const TrayStepBody()),
      _ => ('', '', const SizedBox.shrink()),
    };

    // One primary action: the thing this step needs, then Next.
    final (String primaryLabel, VoidCallback primary) = switch (id) {
      'mic' when !done => (_micAsked ? 'Open app settings' : 'Allow microphone', _micAsked ? () => unawaited(system.openAppDetails()) : () => unawaited(_requestMic())),
      'keyboard' when !done => ('Keyboard settings', () => unawaited(system.openKeyboardSettings())),
      'bubble' when !done => ('Open settings', () => unawaited(system.openBubbleSettings())),
      'hotkey' when !done && !android => ('Bind shortcut', () => unawaited(_bindHotkey())),
      'welcome' => ('Get started', _next),
      _ when last => ('Finish', _next),
      _ => ('Next', _next),
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
                            label: 'Step ${_step + 1} of ${steps.length}',
                            child: Row(
                              children: [
                                for (var i = 0; i < steps.length; i++) ...[
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
                        TextButton(onPressed: _skipAll, child: const Text('Skip setup')),
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
                        if (!last && id != 'welcome' && (primaryLabel != 'Next'))
                          TextButton(onPressed: _next, child: const Text('Skip')),
                        const SizedBox(width: Space.x1),
                        // Never wider than the row: long labels shrink instead of running off screen.
                        Flexible(
                          child: FilledButton(
                            onPressed: primary,
                            child: Text(primaryLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
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

  Future<void> _bindHotkey() async {
    final hotkeys = ref.read(platformServicesProvider).hotkeys;
    if (hotkeys == null) return;
    ref.read(hotkeyStatusProvider.notifier).set(await hotkeys.bind());
    ref.invalidate(setupStatusProvider);
  }
}
