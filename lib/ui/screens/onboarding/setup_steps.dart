// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/cleanup/cleanup_engine.dart';
import '../../../core/dictation/dictation_controller.dart';
import '../../../platform/android/android_system.dart';
import '../../theme/app_theme.dart';
import '../../util/hotkey_state.dart';
import '../../util/platform_flags.dart';
import '../../widgets/engine_picker.dart';
import '../../widgets/mic_button.dart';
import '../settings/linux_section.dart';
import 'setup_status.dart';

/// One line that says whether a step is done yet.
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.done, required this.doneText, required this.waitingText});

  final bool done;
  final String doneText;
  final String waitingText;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Row(
        children: [
          Icon(done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, size: 20, color: done ? c.primary : c.outline),
          const SizedBox(width: 8),
          Expanded(child: Text(done ? doneText : waitingText, style: t.titleSmall?.copyWith(color: done ? c.onSurface : c.onSurfaceVariant))),
        ],
      ),
    );
  }
}

/// A numbered mini-step with an icon as its picture.
class MiniStep extends StatelessWidget {
  const MiniStep({super.key, required this.n, required this.icon, required this.text});

  final int n;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(color: c.secondaryContainer, borderRadius: BorderRadius.circular(16)),
            child: SizedBox.square(dimension: 48, child: Icon(icon, color: c.onSecondaryContainer)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: '$n  ', style: t.titleMedium?.copyWith(color: c.primary)),
              TextSpan(text: text, style: t.bodyLarge),
            ])),
          ),
        ],
      ),
    );
  }
}

/// A messy ramble turning into clean text, on a loop.
class RambleDemo extends StatefulWidget {
  const RambleDemo({super.key});

  static const messy = 'um so like can you uh send me the the report by friday maybe';
  static const clean = 'Can you send me the report by Friday?';

  @override
  State<RambleDemo> createState() => _RambleDemoState();
}

class _RambleDemoState extends State<RambleDemo> {
  Timer? _timer;
  var _clean = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer?.cancel();
    if (MediaQuery.disableAnimationsOf(context)) {
      _clean = true;
    } else {
      _timer = Timer.periodic(const Duration(milliseconds: 2800), (_) {
        if (mounted) setState(() => _clean = !_clean);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final styles = RambleTextStyles.of(context);
    return Semantics(
      label: 'Example. You say: ${RambleDemo.messy}. Ramble writes: ${RambleDemo.clean}',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(color: c.surfaceContainerLow, borderRadius: BorderRadius.circular(Shapes.extraLarge)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_clean ? 'Ramble writes' : 'You say', style: t.labelLarge?.copyWith(color: c.onSurfaceVariant)),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 96),
                child: AnimatedSwitcher(
                  duration: Motion.of(context, Motion.long),
                  // One text fades out before the other fades in: never both at once.
                  switchInCurve: const Interval(0.5, 1, curve: Curves.easeOut),
                  switchOutCurve: const Interval(0.5, 1, curve: Curves.easeIn),
                  layoutBuilder: (current, previous) => Stack(
                    alignment: AlignmentDirectional.topStart,
                    children: [...previous, ?current],
                  ),
                  child: Text(
                    _clean ? RambleDemo.clean : RambleDemo.messy,
                    key: ValueKey(_clean),
                    style: _clean ? styles.result : t.titleLarge?.copyWith(color: c.onSurfaceVariant, fontWeight: FontWeight.w400),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MicStepBody extends ConsumerWidget {
  const MicStepBody({super.key, required this.status, required this.onTapMic});

  final SetupStatus? status;
  final VoidCallback onTapMic;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: MicButton(size: 176, state: const DictationIdle(), onTap: onTapMic)),
        const SizedBox(height: Space.x3),
        StatusLine(
          done: status?.micGranted ?? false,
          doneText: 'Microphone allowed',
          waitingText: 'Waiting for permission',
        ),
      ],
    );
  }
}

class EngineStepBody extends ConsumerWidget {
  const EngineStepBody({super.key, required this.status});

  final SetupStatus? status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(settingsProvider.select((s) => s.engine));
    final android = ref.watch(isAndroidProvider);
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final onDevice = engine == EngineKind.onDevice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusLine(
          done: status?.engineReady ?? false,
          doneText: onDevice ? 'Model ready' : 'Gemini key saved',
          waitingText: onDevice ? 'Download a model to continue' : 'Add your Gemini key to continue',
        ),
        const SizedBox(height: Space.x2),
        const EnginePicker(inset: 0),
        const SizedBox(height: Space.x2),
        if (onDevice)
          Text(
            android
                ? 'The download keeps going in the background, even when the screen is locked.'
                : 'The download keeps going in the background.',
            style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
          )
        else ...[
          Text('Get a key', style: t.titleSmall),
          const SizedBox(height: 4),
          for (final (i, line) in const [
            'Open aistudio.google.com',
            'Sign in with a Google account',
            'Choose Get API key, then Create key',
            'Paste it above and test it',
          ].indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('${i + 1}.  $line', style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
            ),
          // The link and the free-tier note are already in the Gemini options above.
        ],
      ],
    );
  }
}

class KeyboardStepBody extends StatelessWidget {
  const KeyboardStepBody({super.key, required this.status});

  final SetupStatus? status;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MiniStep(n: 1, icon: Icons.keyboard_alt_outlined, text: 'Open keyboard settings'),
        const MiniStep(n: 2, icon: Icons.toggle_on_outlined, text: 'Turn on Ramble Voice'),
        const MiniStep(n: 3, icon: Icons.swap_horiz_rounded, text: 'Later, pick Ramble from the keyboard switcher to dictate'),
        const SizedBox(height: Space.x2),
        StatusLine(
          done: status?.keyboardEnabled ?? false,
          doneText: 'Ramble keyboard is on',
          waitingText: 'Waiting for the keyboard to be turned on',
        ),
      ],
    );
  }
}

const _oemNeedsLaunchManager = {'honor', 'huawei', 'xiaomi', 'redmi', 'poco', 'oppo', 'vivo', 'realme', 'oneplus'};

class BubbleStepBody extends ConsumerWidget {
  const BubbleStepBody({super.key, required this.status});

  final SetupStatus? status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final maker = ref.watch(manufacturerProvider).value ?? '';
    final oem = _oemNeedsLaunchManager.contains(maker);
    final system = ref.read(androidSystemProvider);
    // "Restricted settings" exist from Android 13.
    final restricted = (ref.watch(androidSdkProvider).value ?? 0) >= 33;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MiniStep(n: 1, icon: Icons.settings_outlined, text: 'Open Accessibility settings'),
        const MiniStep(n: 2, icon: Icons.search_rounded, text: 'Find Ramble Voice in the list'),
        const MiniStep(n: 3, icon: Icons.toggle_on_outlined, text: 'Turn it on and confirm'),
        const SizedBox(height: Space.x2),
        StatusLine(
          done: status?.bubbleEnabled ?? false,
          doneText: 'Floating mic is on',
          waitingText: 'Waiting for the floating mic to be turned on',
        ),
        if (restricted) ...[
          const SizedBox(height: Space.x3),
          Text('If it is greyed out', style: t.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Open the app info page, tap the three dots, then Allow restricted settings.',
            style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: system.openAppDetails,
              icon: const Icon(Icons.info_outline_rounded, size: 18),
              label: const Text('Open app info'),
            ),
          ),
        ],
        if (oem) ...[
          const SizedBox(height: Space.x1),
          Text('On this phone', style: t.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Allow Ramble Voice to start by itself and run in the background, or the system may turn the floating mic off.',
            style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: system.openOemAutostart,
              icon: const Icon(Icons.rocket_launch_outlined, size: 18),
              label: const Text('Open App launch settings'),
            ),
          ),
        ],
        const SizedBox(height: Space.x1),
        StatusLine(
          done: status?.ignoringBattery ?? false,
          doneText: 'Battery use is unrestricted',
          waitingText: 'Optional: keep it running in the background',
        ),
        if (!(status?.ignoringBattery ?? false))
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(onPressed: system.requestIgnoreBattery, child: const Text('Allow background use')),
          ),
      ],
    );
  }
}

/// A text field to dictate into, with something to say.
class TryStepBody extends ConsumerStatefulWidget {
  const TryStepBody({super.key, required this.onTyped});

  final VoidCallback onTyped;

  @override
  ConsumerState<TryStepBody> createState() => _TryStepBodyState();
}

class _TryStepBodyState extends ConsumerState<TryStepBody> {
  final _controller = TextEditingController();
  var _worked = false;
  AndroidSystem? _system;

  @override
  void initState() {
    super.initState();
    // The floating mic normally hides inside Ramble; here it is the thing to try.
    if (ref.read(isAndroidProvider)) {
      _system = AndroidSystem();
      unawaited(_system!.allowBubbleInApp(true));
    }
  }

  @override
  void dispose() {
    unawaited(_system?.allowBubbleInApp(false));
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final android = ref.watch(isAndroidProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Try saying: one get potatoes, two asparagus', style: t.titleMedium),
        const SizedBox(height: Space.x2),
        TextField(
          controller: _controller,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(hintText: 'Tap here, then dictate', alignLabelWithHint: true),
          onChanged: (v) {
            final worked = v.trim().length > 8;
            if (worked && !_worked) widget.onTyped();
            setState(() => _worked = worked);
          },
        ),
        const SizedBox(height: Space.x2),
        StatusLine(done: _worked, doneText: 'That worked', waitingText: 'Waiting for your text'),
        const SizedBox(height: Space.x2),
        Text(
          android
              ? 'Tap the floating mic, or switch to the Ramble keyboard, and speak. Ramble types it in for you.'
              : 'Click in the box, press your shortcut and speak. Ramble types where your cursor is.',
          style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(color: c.secondaryContainer, borderRadius: BorderRadius.circular(16)),
            child: SizedBox.square(dimension: 48, child: Icon(icon, color: c.onSecondaryContainer)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.titleMedium),
                Text(text, style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class TipsStepBody extends StatelessWidget {
  const TipsStepBody({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Tip(
          icon: Icons.tune_rounded,
          title: 'Switch tone with one tap',
          text: 'The chip at the top of the keyboard sets Casual, Professional, Texting or Notes for each app.',
        ),
        _Tip(
          icon: Icons.edit_note_rounded,
          title: 'Edit by voice',
          text: 'Tap Edit, then say "make it shorter" or "fix the name" to change what you just wrote.',
        ),
        _Tip(
          icon: Icons.keyboard_rounded,
          title: 'ABC returns to your keyboard',
          text: 'Typing happens in Gboard. Tap ABC on the Ramble keyboard to go back to it.',
        ),
      ],
    );
  }
}

class WelcomeStepBody extends StatelessWidget {
  const WelcomeStepBody({super.key});

  @override
  Widget build(BuildContext context) => const RambleDemo();
}

class HotkeyStepBody extends ConsumerWidget {
  const HotkeyStepBody({super.key, required this.status});

  final SetupStatus? status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hk = ref.watch(hotkeyStatusProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusLine(
          done: status?.hotkeyBound ?? false,
          doneText: hotkeySummary(hk),
          waitingText: 'No global shortcut yet',
        ),
        const SizedBox(height: Space.x2),
        const LinuxSection(),
      ],
    );
  }
}

class TypingStepBody extends ConsumerWidget {
  const TypingStepBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final services = ref.watch(platformServicesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MiniStep(n: 1, icon: Icons.mic_rounded, text: 'Press your shortcut and speak'),
        const MiniStep(n: 2, icon: Icons.verified_user_outlined, text: 'The first time, your desktop asks to allow remote input. Choose Allow'),
        const MiniStep(n: 3, icon: Icons.keyboard_alt_outlined, text: 'Ramble types the text where your cursor is'),
        const SizedBox(height: Space.x2),
        FutureBuilder<String>(
          future: services.inserter.describe(),
          builder: (context, snap) => Text(
            snap.data == null ? 'Checking how typing works here' : 'Typing method: ${snap.data}',
            style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class TrayStepBody extends StatelessWidget {
  const TrayStepBody({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MiniStep(n: 1, icon: Icons.apps_rounded, text: 'Ramble keeps running in the tray when you close the window'),
        MiniStep(n: 2, icon: Icons.mic_none_rounded, text: 'Use the tray icon to open it again or quit'),
      ],
    );
  }
}
