// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ramble_voice/app/providers.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';
import 'package:ramble_voice/core/style/style_profile.dart';
import 'package:ramble_voice/ime/tone_bar.dart';
import 'package:ramble_voice/ui/util/app_label.dart';
import 'package:ramble_voice/ui/widgets/style_chips.dart';

import 'fakes.dart';

class _Pkg extends CurrentPackageNotifier {
  _Pkg(this.pkg);
  final String? pkg;
  @override
  String? build() => pkg;
}

ChoiceChip chip(WidgetTester tester, String label) =>
    tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

void main() {
  testWidgets('tapping a chip changes the saved tone at once', (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(host(
      Consumer(builder: (context, ref, _) {
        container = ProviderScope.containerOf(context);
        return StyleChips(onEdit: () {});
      }),
      overrides: baseOverrides(),
    ));
    expect(chip(tester, 'Casual').selected, isTrue);
    await tester.tap(find.text('Texting'));
    await tester.pump();
    expect(container.read(settingsProvider).style.preset, StylePreset.texting);
    expect(chip(tester, 'Texting').selected, isTrue);
    expect(chip(tester, 'Casual').selected, isFalse);
  });

  testWidgets('Custom chip only shows when custom instructions exist', (tester) async {
    await tester.pumpWidget(host(StyleChips(onEdit: () {}), overrides: baseOverrides()));
    expect(find.text('Custom'), findsNothing);
    await tester.pumpWidget(host(
      StyleChips(onEdit: () {}),
      overrides: baseOverrides(
        settings: const AppSettings(style: StyleProfile(customInstructions: 'Keep British spelling.')),
      ),
    ));
    expect(find.text('Custom'), findsOneWidget);
  });

  testWidgets('long press and the edit button both open editing', (tester) async {
    var edits = 0;
    await tester.pumpWidget(host(StyleChips(onEdit: () => edits++), overrides: baseOverrides()));
    await tester.longPress(find.text('Notes'));
    await tester.pump();
    expect(edits, 1);
    await tester.tap(find.byTooltip('Edit custom instructions and vocabulary'));
    expect(edits, 2);
  });

  group('keyboard tone menu', () {
    List<Override> keyboard(String? pkg, {AppSettings settings = const AppSettings(onboarded: true)}) => [
          ...baseOverrides(settings: settings),
          currentPackageProvider.overrideWith(() => _Pkg(pkg)),
          appLabelProvider.overrideWith((ref, p) async => p == 'com.google.android.gm' ? 'Gmail' : p),
        ];

    Widget menu(void Function(ProviderContainer) grab) => Consumer(builder: (context, ref, _) {
          grab(ProviderScope.containerOf(context));
          return Row(children: [ToneMenu(onEdit: () {})]);
        });

    testWidgets('shows the built-in tone for the current app', (tester) async {
      await tester.pumpWidget(host(menu((_) {}), overrides: keyboard('com.whatsapp')));
      await tester.pump();
      expect(find.text('Texting'), findsOneWidget);
    });

    testWidgets('picking a tone saves an override for that app only', (tester) async {
      late ProviderContainer container;
      await tester.pumpWidget(host(menu((c) => container = c), overrides: keyboard('com.google.android.gm')));
      await tester.pump();
      expect(find.text('Professional'), findsOneWidget);
      await tester.tap(find.text('Professional'));
      await pumpFor(tester);
      expect(find.text('For Gmail'), findsOneWidget);
      await tester.tap(find.text('Notes'));
      await pumpFor(tester);
      final s = container.read(settingsProvider);
      expect(s.appStyles, {'com.google.android.gm': StylePreset.notes});
      expect(s.style.preset, StylePreset.casual);
      expect(container.read(effectiveStyleProvider).preset, StylePreset.notes);
    });

    testWidgets('unknown app saves the global tone and offers no per-app items', (tester) async {
      late ProviderContainer container;
      await tester.pumpWidget(host(menu((c) => container = c), overrides: keyboard(null)));
      await tester.tap(find.text('Casual'));
      await pumpFor(tester);
      expect(find.textContaining('for all apps'), findsNothing);
      await tester.tap(find.text('Professional'));
      await pumpFor(tester);
      expect(container.read(settingsProvider).style.preset, StylePreset.professional);
      expect(container.read(settingsProvider).appStyles, isEmpty);
    });

    testWidgets('"Use for all apps" makes the tone global and clears the override', (tester) async {
      late ProviderContainer container;
      await tester.pumpWidget(host(
        menu((c) => container = c),
        overrides: keyboard(
          'com.google.android.gm',
          settings: const AppSettings(onboarded: true, appStyles: {'com.google.android.gm': StylePreset.notes}),
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('Notes'));
      await pumpFor(tester);
      await tester.tap(find.text('Use Notes for all apps'));
      await pumpFor(tester);
      final s = container.read(settingsProvider);
      expect(s.style.preset, StylePreset.notes);
      expect(s.appStyles, isEmpty);
    });
  });
}
