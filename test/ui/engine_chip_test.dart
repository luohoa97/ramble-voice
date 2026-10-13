// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/app/providers.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';
import 'package:ramble_voice/ui/widgets/engine_chip.dart';

import 'fakes.dart';

void main() {
  testWidgets('on-device chip shows model and backend', (tester) async {
    await tester.pumpWidget(host(
      EngineChip(onTap: () {}),
      overrides: [
        ...baseOverrides(),
        activeEngineReadinessProvider.overrideWith((ref) async => const EngineReady(detail: 'GPU')),
      ],
    ));
    await tester.pump();
    expect(find.text('On-device · Gemma 4 E4B · GPU'), findsOneWidget);
  });

  testWidgets('gemini chip shows resolved model', (tester) async {
    await tester.pumpWidget(host(
      EngineChip(onTap: () {}),
      overrides: [
        ...baseOverrides(settings: const AppSettings(engine: EngineKind.gemini, onboarded: true)),
        activeEngineReadinessProvider
            .overrideWith((ref) async => const EngineReady(detail: 'gemini-3.5-flash-lite')),
      ],
    ));
    await tester.pump();
    expect(find.text('Gemini · gemini-3.5-flash-lite'), findsOneWidget);
  });

  testWidgets('not ready shows warning text and taps through', (tester) async {
    var tapped = false;
    await tester.pumpWidget(host(
      EngineChip(onTap: () => tapped = true),
      overrides: [
        ...baseOverrides(),
        activeEngineReadinessProvider.overrideWith(
          (ref) async => const EngineNotReady(CleanupFailureKind.modelNotDownloaded, 'x'),
        ),
      ],
    ));
    await tester.pump();
    expect(find.textContaining('Model not downloaded'), findsOneWidget);
    await tester.tap(find.byType(EngineChip));
    expect(tapped, isTrue);
  });
}
