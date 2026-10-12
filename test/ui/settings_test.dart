// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ramble_voice/app/providers.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/models/model_downloader.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';
import 'package:ramble_voice/ui/screens/settings/gemini_section.dart';
import 'package:ramble_voice/ui/screens/settings/model_section.dart';
import 'package:ramble_voice/ui/widgets/engine_picker.dart';

import '../goldens/harness.dart' show FakeDownloads, downloading;
import 'fakes.dart';

void main() {
  void bigView(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('Gemini options show the free-tier warning, key field and fallback switch', (tester) async {
    bigView(tester);
    await tester.pumpWidget(host(const SingleChildScrollView(child: GeminiOptions()), overrides: baseOverrides()));
    await tester.pump();
    expect(find.text('Free-tier requests may be used by Google to improve its products.'), findsOneWidget);
    expect(find.text('Gemini API key'), findsOneWidget);
    expect(find.text('Save key'), findsOneWidget);
    expect(find.text('Test key'), findsOneWidget);
    expect(find.text('If Gemini is unavailable, use the on-device model'), findsOneWidget);
  });

  testWidgets('a saved key shows a masked row instead of the field', (tester) async {
    bigView(tester);
    final secrets = FakeSecrets()..source = KeySource.secureStorage;
    await tester.pumpWidget(host(
      const SingleChildScrollView(child: GeminiOptions()),
      overrides: baseOverrides(secrets: secrets),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('API key'), findsOneWidget);
    expect(find.text('Saved on this device'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('engine picker has two radio rows and opens options for the selected one', (tester) async {
    bigView(tester);
    await tester.pumpWidget(host(
      const SingleChildScrollView(child: EnginePicker()),
      overrides: baseOverrides(),
    ));
    await tester.pump();
    expect(find.text('On-device'), findsOneWidget);
    expect(find.text('Gemini cloud'), findsOneWidget);
    expect(find.text(engineTaglines[EngineKind.onDevice]!), findsOneWidget);
    // On-device is selected: its model rows are visible, Gemini's are not.
    expect(find.text('Gemma 4 E4B'), findsOneWidget);
    expect(find.text('Gemma 4 E2B'), findsOneWidget);
    expect(find.text('Gemini API key'), findsNothing);

    await tester.tap(find.text('Gemini cloud'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Gemma 4 E4B'), findsNothing);
    expect(find.text('Gemini API key'), findsOneWidget);
  });

  testWidgets('selected engine row is marked checked for accessibility', (tester) async {
    bigView(tester);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(
      const SingleChildScrollView(child: EnginePicker()),
      overrides: baseOverrides(),
    ));
    await tester.pump();
    final node = tester.getSemantics(find.text('On-device'));
    expect(node.flagsCollection.isChecked, isNotNull);
    handle.dispose();
  });

  testWidgets('model rows list variants and mark E4B recommended', (tester) async {
    bigView(tester);
    await tester.pumpWidget(host(const SingleChildScrollView(child: ModelChoices()), overrides: baseOverrides()));
    await tester.pump();
    expect(find.text('Gemma 4 E4B'), findsOneWidget);
    expect(find.text('Gemma 4 E2B'), findsOneWidget);
    expect(find.text('Recommended'), findsOneWidget);
    expect(find.text('Download'), findsNWidgets(2));
  });

  testWidgets('downloading row offers pause and cancel when the downloader can pause', (tester) async {
    bigView(tester);
    await tester.pumpWidget(host(
      const SingleChildScrollView(child: ModelChoices()),
      overrides: [
        ...baseOverrides(),
        modelDownloaderProvider.overrideWithValue(FakeDownloads({'gemma-4-e4b': downloading(0.4)})),
      ],
    ));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('downloading row only offers Cancel without pause support', (tester) async {
    bigView(tester);
    await tester.pumpWidget(host(
      const SingleChildScrollView(child: ModelChoices()),
      overrides: [
        ...baseOverrides(),
        modelDownloaderProvider.overrideWithValue(FakeDownloads({'gemma-4-e4b': downloading(0.4)}, canPause: false)),
      ],
    ));
    await tester.pump();
    expect(find.text('Pause'), findsNothing);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('tapping a downloaded variant selects it', (tester) async {
    bigView(tester);
    late ProviderContainer container;
    await tester.pumpWidget(host(
      Consumer(builder: (context, ref, _) {
        container = ProviderScope.containerOf(context);
        return const SingleChildScrollView(child: ModelChoices());
      }),
      overrides: [
        ...baseOverrides(),
        modelDownloaderProvider.overrideWithValue(FakeDownloads({'gemma-4-e2b': const Downloaded('/x')})),
      ],
    ));
    await tester.pump();
    expect(container.read(settingsProvider).gemmaVariantId, 'gemma-4-e4b');
    await tester.tap(find.text('Gemma 4 E2B'));
    await tester.pump();
    expect(container.read(settingsProvider).gemmaVariantId, 'gemma-4-e2b');
  });
}
