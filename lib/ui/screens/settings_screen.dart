// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../core/cleanup/cleanup_engine.dart';
import '../util/platform_flags.dart';
import '../widgets/section_card.dart';
import 'settings/gemini_section.dart';
import 'settings/linux_section.dart';
import 'settings/misc_sections.dart';
import 'settings/model_section.dart';
import 'settings/style_section.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLinux = ref.watch(isLinuxProvider);
    final isAndroid = ref.watch(isAndroidProvider);
    final engine = ref.watch(settingsProvider.select((s) => s.engine));

    final sections = <Widget>[
      const SectionCard(title: 'Engine', children: [EngineSection()]),
      SectionCard(
        title: 'On-device model',
        subtitle: engine == EngineKind.onDevice ? 'Used for cleanup now' : 'Used as the fallback in cloud mode',
        children: const [ModelSection()],
      ),
      const SectionCard(title: 'Gemini', children: [GeminiSection()]),
      const SectionCard(title: 'Style', children: [StyleSection()]),
      const SectionCard(title: 'Recording', children: [RecordingSection()]),
      if (isLinux) const SectionCard(title: 'Linux', children: [LinuxSection()]),
      if (isAndroid) const SectionCard(title: 'Keyboard', children: [AndroidSection()]),
      const SectionCard(title: 'Privacy', children: [PrivacySection()]),
      const SectionCard(title: 'About', children: [AboutSection()]),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              itemCount: sections.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, i) => sections[i],
            ),
          ),
        ),
      ),
    );
  }
}
