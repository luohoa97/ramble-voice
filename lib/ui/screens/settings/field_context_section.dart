// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../widgets/settings_section.dart';

/// Keyboard only: dictation continues the sentence already in the field.
/// Hidden on platforms without the keyboard.
class FieldContextSection extends ConsumerWidget {
  const FieldContextSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final on = ref.watch(settingsProvider.select((s) => s.useFieldContext));
    return SettingsSection(
      title: 'Context',
      children: [
        SwitchListTile(
          value: on,
          title: const Text('Continue my sentence'),
          subtitle: const Text(
            'Use text around the cursor so dictation continues your sentence. '
            'In Gemini mode this text is sent to Google with the audio.',
          ),
          onChanged: (v) => unawaited(ref.read(settingsProvider.notifier).update((s) => s.copyWith(useFieldContext: v))),
        ),
        SwitchListTile(
          value: ref.watch(settingsProvider.select((s) => s.screenContext)),
          title: const Text('Conversation context'),
          subtitle: const Text(
            'When you dictate a reply, Ramble reads the messages shown on screen (WhatsApp, Discord, Messages, email) '
            'so your words, names and tone fit the conversation. Needs the floating mic switched on. '
            'In Gemini mode those messages are sent to Google with the audio; nothing is stored.',
          ),
          onChanged: (v) => unawaited(ref.read(settingsProvider.notifier).update((s) => s.copyWith(screenContext: v))),
        ),
      ],
    );
  }
}
