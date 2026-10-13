// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../util/open_url.dart';
import '../../util/platform_flags.dart';
import '../../util/system_channel.dart';
import '../history_screen.dart';

class RecordingSection extends ConsumerWidget {
  const RecordingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final android = ref.watch(isAndroidProvider);
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final minutes = s.maxSessionMinutes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              Expanded(child: Text('Maximum length', style: t.bodyLarge)),
              Text('$minutes ${minutes == 1 ? 'minute' : 'minutes'}', style: t.titleMedium?.copyWith(color: c.primary)),
            ],
          ),
        ),
        Slider(
          min: 1,
          max: 30,
          divisions: 29,
          value: minutes.clamp(1, 30).toDouble(),
          label: '$minutes min',
          semanticFormatterCallback: (v) => '${v.round()} minutes',
          onChanged: (v) => ref.read(settingsProvider.notifier).update((x) => x.copyWith(maxSessionMinutes: v.round())),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Recording stops and is cleaned up automatically at this length.',
            style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
          ),
        ),
        if (android)
          SwitchListTile(
            contentPadding: const EdgeInsets.only(left: 16, right: 8),
            title: const Text('Haptic feedback'),
            value: s.haptics,
            onChanged: (v) => ref.read(settingsProvider.notifier).update((x) => x.copyWith(haptics: v)),
          ),
        if (android)
          SwitchListTile(
            contentPadding: const EdgeInsets.only(left: 16, right: 8),
            title: const Text('Phone noise reduction'),
            subtitle: const Text('Uses the phone\'s call noise filter on the microphone. Try it on buses and in loud places.'),
            value: s.noiseReduction,
            onChanged: (v) => ref.read(settingsProvider.notifier).update((x) => x.copyWith(noiseReduction: v)),
          ),
      ],
    );
  }
}

class AndroidSection extends ConsumerStatefulWidget {
  const AndroidSection({super.key});

  @override
  ConsumerState<AndroidSection> createState() => _AndroidSectionState();
}

class _AndroidSectionState extends ConsumerState<AndroidSection> with WidgetsBindingObserver {
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final v = await SystemChannel.isKeyboardEnabled();
    if (mounted) setState(() => _enabled = v);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final enabled = _enabled == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Dictate in any app with the Ramble keyboard. Switch to it from the keyboard picker, then tap the microphone.',
            style: t.bodyLarge,
          ),
        ),
        ListTile(
          contentPadding: const EdgeInsets.only(left: 16, right: 8),
          leading: Icon(enabled ? Icons.check_circle_rounded : Icons.keyboard_alt_outlined, color: enabled ? c.primary : c.onSurfaceVariant),
          title: Text(_enabled == null ? 'Checking keyboard status' : (enabled ? 'Keyboard is enabled' : 'Keyboard is not enabled')),
          trailing: enabled
              ? null
              : FilledButton.tonal(onPressed: SystemChannel.openKeyboardSettings, child: const Text('Enable')),
        ),
      ],
    );
  }
}

class PrivacySection extends ConsumerWidget {
  const PrivacySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Dictation runs on this device by default. Nothing leaves it except audio sent to Gemini when you choose Gemini cloud, and model downloads. There is no telemetry and no account.',
            style: t.bodyLarge,
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: const EdgeInsets.only(left: 16, right: 8),
          title: const Text('Usage log on this device'),
          subtitle: const Text(
            'Keeps a record of engines, models, timings and failures (never your words) to help fix problems. '
            'It stays on this device unless you share it.',
          ),
          value: ref.watch(settingsProvider.select((s) => s.usageLog)),
          onChanged: (v) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(usageLog: v)),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: const Icon(Icons.ios_share_rounded),
          title: const Text('Share usage log'),
          subtitle: const Text('Attach it to a bug report or contribution'),
          onTap: () async {
            final text = await ref.read(usageLogProvider).readAll();
            if (text.isEmpty) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The usage log is empty')));
              }
              return;
            }
            final share = ref.read(platformServicesProvider).share;
            if (share != null) {
              await share(text);
            } else {
              await ref.read(platformServicesProvider).inserter.copy(text);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Usage log copied')));
              }
            }
          },
        ),
        if (ref.watch(isAndroidProvider))
          SwitchListTile(
            contentPadding: const EdgeInsets.only(left: 16, right: 8),
            title: const Text('Diagnostics over adb'),
            subtitle: const Text(
              'Lets a computer connected with USB or wireless debugging read your dictation history, to diagnose '
              'problems on your own phone. Leave off unless you are testing.',
            ),
            value: ref.watch(settingsProvider.select((s) => s.adbDiagnostics)),
            onChanged: (v) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(adbDiagnostics: v)),
          ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: Icon(Icons.delete_outline_rounded, color: c.error),
          title: Text('Delete all history and recordings', style: TextStyle(color: c.error)),
          onTap: () async {
            if (!await confirmDeleteAll(context)) return;
            await deleteEverything(ref);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('History and recordings deleted')));
            }
          },
        ),
      ],
    );
  }
}

class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('Ramble Voice $appVersion'),
          subtitle: Text(
            'Free software under the GNU GPL, version 3 or later.',
            style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
          ),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: const Icon(Icons.code_rounded),
          title: const Text('Source code'),
          onTap: () => openUrl(appSourceUrl),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: const Icon(Icons.description_outlined),
          title: const Text('Third-party licenses'),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Ramble Voice',
            applicationVersion: appVersion,
            applicationLegalese: 'GPL-3.0-or-later',
          ),
        ),
      ],
    );
  }
}
