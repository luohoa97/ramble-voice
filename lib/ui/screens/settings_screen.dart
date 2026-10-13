// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';
import '../util/platform_flags.dart';
import '../widgets/engine_picker.dart';
import '../widgets/settings_section.dart';
import '../widgets/style_chips.dart';
import 'settings/app_styles_section.dart';
import 'settings/bubble_section.dart';
import 'settings/field_context_section.dart';
import 'settings/names_section.dart';
import 'settings/polish_section.dart';
import 'settings/language_section.dart';
import 'settings/linux_section.dart';
import 'settings/misc_sections.dart';
import 'settings/snippets_section.dart';
import 'settings/style_section.dart';

/// A settings category: one page of related sections.
enum SettingsCategory {
  engine('engine', 'Engine and models', 'On-device Gemma or Gemini, models, NPU', Icons.memory_rounded),
  writing('writing', 'Writing style', 'Tone, per-app tones, polish, languages, names, shortcuts', Icons.edit_note_rounded),
  dictation('dictation', 'Keyboard and floating mic', 'Context, recording, keyboard, floating mic', Icons.keyboard_rounded),
  desktop('desktop', 'Desktop', 'Shortcut, typing into apps, tray', Icons.desktop_windows_rounded),
  privacy('privacy', 'Privacy', 'What leaves the device, usage log, history', Icons.lock_outline_rounded),
  about('about', 'Help and about', 'Setup guide, licenses, version', Icons.info_outline_rounded);

  const SettingsCategory(this.id, this.title, this.summary, this.icon);
  final String id;
  final String title;
  final String summary;
  final IconData icon;

  static SettingsCategory? byId(String? id) => values.where((c) => c.id == id).firstOrNull;
}

/// Settings: a list of categories (Material 3 settings pattern), each opening
/// a page of its own instead of one long, crammed scroll.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key, this.category});

  /// The category page to show; null shows the list of categories.
  final SettingsCategory? category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLinux = ref.watch(isLinuxProvider);
    final isAndroid = ref.watch(isAndroidProvider);
    final wide = MediaQuery.sizeOf(context).width >= kTwoPaneWidth;
    final c = category;

    final available = [
      for (final k in SettingsCategory.values)
        if (k != SettingsCategory.dictation || isAndroid)
          if (k != SettingsCategory.desktop || isLinux) k,
    ];

    // Every section's own rows get the same side margin.
    Widget padded(Widget child) => Padding(padding: const EdgeInsets.symmetric(horizontal: Space.gutter), child: child);

    final List<Widget> sections = switch (c) {
      null => [
          for (final k in available)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 4),
              leading: CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
                child: Icon(k.icon),
              ),
              title: Text(k.title),
              subtitle: Text(k.summary),
              onTap: () => context.go('/settings/${k.id}'),
            ),
        ],
      SettingsCategory.engine => [
          const SettingsSection(title: 'Engine', children: [EnginePicker(showPath: true)]),
        ],
      SettingsCategory.writing => [
          SettingsSection(
            title: 'Tone',
            subtitle: 'Applied to every dictation. Switch it any time on the record screen or the keyboard.',
            children: [
              const StyleChips(centered: false),
              const SizedBox(height: Space.x2),
              const TextSpeakSwitch(),
              const SizedBox(height: Space.x2),
              padded(const StyleEditor()),
            ],
          ),
          if (isAndroid) const SettingsSection(title: 'Per-app tones', children: [AppStylesSection()]),
          const PolishSection(),
          const LanguageSection(),
          const ContactNamesSection(),
          const SnippetsSection(),
        ],
      SettingsCategory.dictation => [
          if (isAndroid) const FieldContextSection(),
          const SettingsSection(title: 'Recording', children: [RecordingSection()]),
          const SettingsSection(title: 'Keyboard', children: [AndroidSection()]),
          const SettingsSection(title: 'Your email addresses', children: [MyEmailsSection()]),
          SettingsSection(title: 'Floating mic', children: [padded(const BubbleSection())]),
        ],
      SettingsCategory.desktop => [
          SettingsSection(title: 'Linux', children: [padded(const LinuxSection())]),
          const SettingsSection(title: 'Recording', children: [RecordingSection()]),
        ],
      SettingsCategory.privacy => [const SettingsSection(title: 'Privacy', children: [PrivacySection()])],
      SettingsCategory.about => [
          SettingsSection(
            title: 'Help',
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                leading: const Icon(Icons.checklist_rounded),
                title: const Text('Setup guide'),
                subtitle: const Text('Microphone, engine, keyboard and the floating mic'),
                onTap: () => context.push('/setup'),
              ),
            ],
          ),
          const SettingsSection(title: 'About', children: [AboutSection()]),
        ],
    };

    final back = c != null
        ? IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => context.go('/settings'),
          )
        : wide
            ? IconButton(
                tooltip: 'Back to recording',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => context.go('/'),
              )
            : null;

    return CallbackShortcuts(
      bindings: {
        if (wide || c != null)
          const SingleActivator(LogicalKeyboardKey.escape): () => context.go(c != null ? '/settings' : '/'),
      },
      child: PopScope(
        canPop: c == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && c != null) context.go('/settings');
        },
        child: SafeArea(
          bottom: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kContentWidth),
              child: FocusTraversalGroup(
                policy: ReadingOrderTraversalPolicy(),
                // Not a lazy ListView: sections differ in height and some grow
                // after loading, which made a lazy list jump while scrolling.
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: Space.x4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ScreenTitle(c?.title ?? 'Settings', leading: back),
                      ...sections,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
