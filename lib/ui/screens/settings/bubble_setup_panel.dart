// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../platform/android/bubble_setup.dart';

/// Walks the user through turning the floating mic on, one needed step at a
/// time. Mount it in settings or in an onboarding step; [onDone] fires once
/// everything is set up.
class BubbleSetupPanel extends StatefulWidget {
  const BubbleSetupPanel({super.key, this.onDone, this.env});

  final VoidCallback? onDone;

  /// Injected in tests.
  final BubbleSetupEnv? env;

  @override
  State<BubbleSetupPanel> createState() => _BubbleSetupPanelState();
}

class _BubbleSetupPanelState extends State<BubbleSetupPanel> with WidgetsBindingObserver {
  late final BubbleSetup _setup = BubbleSetup(widget.env ?? AndroidBubbleSetupEnv());
  bool _doneSent = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setup.addListener(_changed);
    unawaited(_setup.start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _setup.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_setup.refresh());
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_setup.finished && !_doneSent) {
      _doneSent = true;
      widget.onDone?.call();
    }
  }

  static const _titles = {
    BubbleSetupStep.microphone: 'Allow the microphone',
    BubbleSetupStep.keyboard: 'Enable the Ramble keyboard',
    BubbleSetupStep.accessibility: 'Turn on the floating mic',
    BubbleSetupStep.battery: 'Allow unrestricted battery',
    BubbleSetupStep.autostart: 'Allow auto-launch',
  };

  static const _bodies = {
    BubbleSetupStep.microphone: 'Ramble Voice needs the microphone to hear you.',
    BubbleSetupStep.keyboard:
        'Tapping the mic switches to the Ramble keyboard to listen, then back to your own. Turn Ramble Voice on in the list.',
    BubbleSetupStep.accessibility:
        'Choose Ramble Voice floating mic and switch it on. It shows the mic next to text fields and inserts your text. '
            'It does not read or store screen content.',
    BubbleSetupStep.battery: 'This keeps your phone from stopping the floating mic to save battery.',
    BubbleSetupStep.autostart:
        'Set Ramble Voice to "Manage manually" and allow auto-launch, secondary launch and run in background '
            '(on Xiaomi, turn on Autostart).',
  };

  static const _actions = {
    BubbleSetupStep.microphone: 'Allow microphone',
    BubbleSetupStep.keyboard: 'Open keyboard settings',
    BubbleSetupStep.accessibility: 'Open accessibility settings',
    BubbleSetupStep.battery: 'Allow unrestricted battery',
    BubbleSetupStep.autostart: 'Open launch settings',
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    if (!_setup.started) return const SizedBox.shrink();
    final step = _setup.current;
    if (step == null) {
      return Row(
        children: [
          Icon(Icons.check_circle_rounded, color: c.primary),
          const SizedBox(width: 8),
          Text('Floating mic is on', style: t.titleSmall),
        ],
      );
    }
    final restricted = step == BubbleSetupStep.accessibility && _setup.restricted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step ${_setup.number} of ${_setup.steps.length}', style: t.labelMedium?.copyWith(color: c.onSurfaceVariant)),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: (_setup.number - 1) / _setup.steps.length),
        const SizedBox(height: 12),
        Semantics(
          header: true,
          child: Text(restricted ? 'Android blocked this setting' : _titles[step]!, style: t.titleSmall),
        ),
        const SizedBox(height: 4),
        Text(
          restricted
              ? 'Android blocked this setting for sideloaded apps. Open App info, tap the three dots at the top right, '
                  'choose "Allow restricted settings", then come back.'
              : _bodies[step]!,
          style: t.bodyMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (restricted) ...[
              FilledButton.icon(
                onPressed: _setup.act,
                icon: const Icon(Icons.info_outline_rounded),
                label: const Text('Open App info'),
              ),
              OutlinedButton(onPressed: _setup.retryAccessibility, child: const Text('Try again')),
            ] else
              FilledButton(onPressed: _setup.act, child: Text(_actions[step]!)),
            if (step == BubbleSetupStep.battery || step == BubbleSetupStep.autostart)
              TextButton(onPressed: _setup.skip, child: const Text('Skip')),
          ],
        ),
      ],
    );
  }
}
