// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/cleanup/cleanup_engine.dart';
import '../../util/open_url.dart';
import '../../util/platform_flags.dart';
import '../../util/system_channel.dart';
import '../history_screen.dart';

const engineTaglines = {
  EngineKind.onDevice: 'On-device (private, free, offline)',
  EngineKind.gemini: 'Gemini cloud (smarter, needs internet)',
};

class EngineSection extends ConsumerWidget {
  const EngineSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(settingsProvider.select((s) => s.engine));
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<EngineKind>(
          segments: const [
            ButtonSegment(value: EngineKind.onDevice, label: Text('On-device'), icon: Icon(Icons.memory_rounded)),
            ButtonSegment(value: EngineKind.gemini, label: Text('Gemini cloud'), icon: Icon(Icons.cloud_outlined)),
          ],
          selected: {engine},
          showSelectedIcon: false,
          onSelectionChanged: (s) {
            ref.read(settingsProvider.notifier).update((x) => x.copyWith(engine: s.first));
          },
        ),
        const SizedBox(height: 12),
        Semantics(
          liveRegion: true,
          child: Text(engineTaglines[engine]!, style: t.bodyLarge?.copyWith(color: c.onSurfaceVariant)),
        ),
      ],
    );
  }
}

class RecordingSection extends ConsumerWidget {
  const RecordingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final android = ref.watch(isAndroidProvider);
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Maximum length: ${s.maxSessionMinutes} ${s.maxSessionMinutes == 1 ? 'minute' : 'minutes'}', style: t.titleMedium),
        Slider(
          min: 1,
          max: 30,
          divisions: 29,
          value: s.maxSessionMinutes.clamp(1, 30).toDouble(),
          label: '${s.maxSessionMinutes} min',
          semanticFormatterCallback: (v) => '${v.round()} minutes',
          onChanged: (v) => ref.read(settingsProvider.notifier).update((x) => x.copyWith(maxSessionMinutes: v.round())),
        ),
        Text('Recording stops and is cleaned up automatically at this length.', style: t.bodySmall),
        if (android)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Haptic feedback'),
            value: s.haptics,
            onChanged: (v) => ref.read(settingsProvider.notifier).update((x) => x.copyWith(haptics: v)),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Dictate in any app with the Ramble keyboard. Switch to it from the keyboard picker, then tap the microphone.',
          style: t.bodyMedium,
        ),
        const SizedBox(height: 8),
        Text(
          _enabled == null ? 'Checking keyboard status' : (_enabled! ? 'Keyboard is enabled' : 'Keyboard is not enabled'),
          style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.tonalIcon(
            onPressed: SystemChannel.openKeyboardSettings,
            icon: const Icon(Icons.keyboard_rounded),
            label: const Text('Enable Ramble keyboard'),
          ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Dictation runs on this device by default. Nothing leaves it except audio sent to Gemini when you choose Gemini cloud, and model downloads. There is no telemetry and no account.',
          style: t.bodyLarge,
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () async {
            if (!await confirmDeleteAll(context)) return;
            await deleteEverything(ref);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('History and recordings deleted')));
            }
          },
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('Delete all history and recordings'),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Ramble Voice $appVersion', style: t.titleMedium),
        const SizedBox(height: 4),
        Text('Free software under the GNU GPL, version 3 or later (GPL-3.0-or-later).', style: t.bodyMedium),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => openUrl(appSourceUrl),
              icon: const Icon(Icons.code_rounded),
              label: const Text('Source code'),
            ),
            OutlinedButton.icon(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Ramble Voice',
                applicationVersion: appVersion,
                applicationLegalese: 'GPL-3.0-or-later',
              ),
              icon: const Icon(Icons.description_outlined),
              label: const Text('Third-party licenses'),
            ),
          ],
        ),
      ],
    );
  }
}
