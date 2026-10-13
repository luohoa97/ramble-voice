// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/cleanup/cleanup_engine.dart';
import '../../../platform/android/android_contact_names.dart';
import '../../widgets/settings_section.dart';

/// Opt-in: use contact names as spelling hints. Hidden where there is no
/// address book to read.
class ContactNamesSection extends ConsumerWidget {
  const ContactNamesSection({super.key});

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool on) async {
    if (on && Platform.isAndroid && !await AndroidContactNames.request()) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Contacts access was not granted.')),
        );
      }
      return;
    }
    ref.read(contactNamesCacheProvider)?.invalidate();
    await ref.read(settingsProvider.notifier).update((s) => s.copyWith(useContactNames: on));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(contactNameSourceProvider) == null) return const SizedBox.shrink();
    final s = ref.watch(settingsProvider.select((s) => (s.useContactNames, s.engine)));
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return SettingsSection(
      title: 'Names',
      children: [
        SwitchListTile(
          value: s.$1,
          title: const Text('Spell my contacts\' names correctly'),
          subtitle: Text(
            Platform.isAndroid ? 'Uses your contacts. Needs contacts access.' : 'Uses your GNOME Contacts / Evolution address book.',
          ),
          onChanged: (on) => unawaited(_toggle(context, ref, on)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Text(
            s.$2 == EngineKind.gemini
                ? 'In Gemini mode your contact names are sent to Google with each request.'
                : 'In Gemini mode your contact names would be sent to Google with each request. '
                    'On-device mode keeps them on this device.',
            style: t.bodySmall?.copyWith(color: s.$1 && s.$2 == EngineKind.gemini ? c.error : c.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
