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
import 'settings/language_section.dart';
import 'settings/linux_section.dart';
import 'settings/misc_sections.dart';
import 'settings/snippets_section.dart';
import 'settings/style_section.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.anchor});

  /// Section to scroll to on open: `engine` or `style`.
  final String? anchor;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _anchors = {'engine': GlobalKey(), 'style': GlobalKey()};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _anchors[widget.anchor]?.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, duration: Duration.zero);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLinux = ref.watch(isLinuxProvider);
    final isAndroid = ref.watch(isAndroidProvider);
    final wide = MediaQuery.sizeOf(context).width >= kTwoPaneWidth;

    final sections = <Widget>[
      KeyedSubtree(key: _anchors['engine'], child: const SettingsSection(title: 'Engine', children: [EnginePicker(showPath: true)])),
      KeyedSubtree(
        key: _anchors['style'],
        child: const SettingsSection(
        title: 'Style',
        subtitle: 'The tone is applied to every dictation. Switch it any time on the record screen.',
        children: [
          StyleChips(centered: false),
          SizedBox(height: Space.x3),
          Padding(padding: EdgeInsets.symmetric(horizontal: Space.gutter), child: StyleEditor()),
        ],
      )),
      if (isAndroid) const SettingsSection(title: 'Per-app styles', children: [AppStylesSection()]),
      const LanguageSection(),
      const SnippetsSection(),
      const SettingsSection(title: 'Recording', children: [RecordingSection()]),
      if (isLinux)
        const SettingsSection(
          title: 'Linux',
          children: [Padding(padding: EdgeInsets.symmetric(horizontal: Space.gutter), child: LinuxSection())],
        ),
      if (isAndroid) const SettingsSection(title: 'Keyboard', children: [AndroidSection()]),
      if (isAndroid) const SettingsSection(title: 'Floating mic', children: [BubbleSection()]),
      const SettingsSection(title: 'Privacy', children: [PrivacySection()]),
      const SettingsSection(title: 'About', children: [AboutSection()]),
    ];

    return CallbackShortcuts(
      bindings: {if (wide) const SingleActivator(LogicalKeyboardKey.escape): () => context.go('/')},
      child: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kContentWidth),
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: ListView(
                padding: const EdgeInsets.only(bottom: Space.x4),
                children: [
                  ScreenTitle(
                    'Settings',
                    leading: wide
                        ? IconButton(
                            tooltip: 'Back to recording',
                            icon: const Icon(Icons.arrow_back_rounded),
                            onPressed: () => context.go('/'),
                          )
                        : null,
                  ),
                  ...sections,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
