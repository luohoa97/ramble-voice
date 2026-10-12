// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ramble_voice/ui/screens/settings/gemini_section.dart';
import 'package:ramble_voice/ui/screens/settings/misc_sections.dart';
import 'package:ramble_voice/ui/screens/settings/model_section.dart';

import 'fakes.dart';

void main() {
  testWidgets('Gemini section shows the free-tier warning and guide', (tester) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(
      const SingleChildScrollView(child: GeminiSection()),
      overrides: baseOverrides(),
    ));
    await tester.pump();
    expect(find.text('Free-tier requests may be used by Google to improve its products.'), findsOneWidget);
    expect(find.text('Go to aistudio.google.com'), findsOneWidget);
    expect(find.text('Test key'), findsOneWidget);
    expect(find.text('If Gemini is unavailable, use the on-device model'), findsOneWidget);
  });

  testWidgets('engine section shows exact taglines', (tester) async {
    await tester.pumpWidget(host(const EngineSection(), overrides: baseOverrides()));
    await tester.pump();
    expect(find.text('On-device (private, free, offline)'), findsOneWidget);
    await tester.tap(find.text('Gemini cloud'));
    await tester.pump();
    expect(find.text('Gemini cloud (smarter, needs internet)'), findsOneWidget);
  });

  testWidgets('model section lists variants and marks E4B recommended', (tester) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(const SingleChildScrollView(child: ModelSection()), overrides: baseOverrides()));
    await tester.pump();
    expect(find.text('Gemma 4 E4B'), findsOneWidget);
    expect(find.text('Gemma 4 E2B'), findsOneWidget);
    expect(find.text('Recommended'), findsOneWidget);
  });
}
