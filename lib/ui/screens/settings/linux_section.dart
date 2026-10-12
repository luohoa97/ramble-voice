// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../platform/linux/host_setup.dart';
import '../../../platform/platform_services.dart';
import '../../theme/app_theme.dart';
import '../../util/clipboard.dart';
import '../../util/hotkey_state.dart';

String hotkeySummary(HotkeyStatus? s) {
  if (s == null) return 'Shortcut status unknown';
  return switch (s.backend) {
    HotkeyBackend.none => 'No global shortcut is active',
    _ => s.trigger == null
        ? 'Global shortcut is active'
        : 'Shortcut: ${s.trigger}${s.supportsRelease ? ' (hold to talk)' : ' (press to start and stop)'}',
  };
}

class LinuxSection extends ConsumerWidget {
  const LinuxSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(platformServicesProvider);
    final hotkeys = services.hotkeys;
    final status = ref.watch(hotkeyStatusProvider);
    final settings = ref.watch(settingsProvider);
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Global shortcut', style: t.titleMedium),
        const SizedBox(height: 4),
        Semantics(liveRegion: true, child: Text(hotkeySummary(status), style: t.bodyLarge)),
        if (status?.message != null) ...[
          const SizedBox(height: 8),
          _CopyBox(text: status!.message!),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (hotkeys != null)
              FilledButton.tonal(
                onPressed: () async => ref.read(hotkeyStatusProvider.notifier).set(await hotkeys.bind()),
                child: Text(status == null || status.backend == HotkeyBackend.none ? 'Bind shortcut' : 'Bind again'),
              ),
            if (hotkeys != null)
              OutlinedButton(
                onPressed: () async {
                  final ok = await hotkeys.configure();
                  if (!ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Change the shortcut in your desktop settings.'),
                    ));
                  }
                },
                child: const Text('Change shortcut'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text('Compositor key bindings can run these commands:', style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
        const SizedBox(height: 4),
        const _CopyBox(text: 'ramble_voice --toggle\nramble_voice --start\nramble_voice --stop'),
        const SizedBox(height: 20),
        Text('Text insertion', style: t.titleMedium),
        const SizedBox(height: 4),
        FutureBuilder<String>(
          future: services.inserter.describe(),
          builder: (context, snap) => Text(
            snap.data ?? 'Checking',
            style: t.bodyLarge,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Type into the focused app'),
          subtitle: const Text('When off, shortcut dictation only copies the text to the clipboard.'),
          value: settings.typeIntoFocusedApp,
          onChanged: (v) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(typeIntoFocusedApp: v)),
        ),
        const _HostSetupBlock(),
      ],
    );
  }
}

class _HostSetupBlock extends StatelessWidget {
  const _HostSetupBlock();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return FutureBuilder<bool>(
      future: Future.value(HostSetup.needed()),
      builder: (context, snap) {
        if (snap.data != true) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Optional host setup', style: t.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Some typing tools are missing on this system. Run this command once in a terminal on the host:',
                style: t.bodyMedium,
              ),
              const SizedBox(height: 8),
              _CopyBox(text: HostSetup.command),
            ],
          ),
        );
      },
    );
  }
}

class _CopyBox extends StatelessWidget {
  const _CopyBox({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: c.surfaceContainerHighest, borderRadius: BorderRadius.circular(Shapes.medium)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: SelectableText(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace')),
            ),
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy_rounded, size: 18),
              onPressed: () => copyToClipboard(context, text),
            ),
          ],
        ),
      ),
    );
  }
}
