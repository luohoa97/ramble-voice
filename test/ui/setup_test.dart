// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';
import 'package:ramble_voice/ui/screens/onboarding/setup_status.dart';
import 'package:ramble_voice/ui/util/platform_flags.dart';
import 'package:ramble_voice/ui/widgets/setup_banner.dart';

import 'fakes.dart';

void main() {
  group('step bookkeeping', () {
    test('Android and Linux have their own steps', () {
      expect(
        setupStepsFor(android: true),
        containsAll(['mic', 'keyboard', 'bubble']),
      );
      expect(
        setupStepsFor(android: false),
        containsAll(['hotkey', 'typing', 'tray']),
      );
      expect(setupStepsFor(android: false), isNot(contains('keyboard')));
    });

    test('detected steps count as done, the rest need to be completed', () {
      final steps = setupStepsFor(android: true);
      const s = SetupStatus(micGranted: true, engineReady: true);
      expect(stepsLeft(steps, s, const {}), steps.length - 2);
      expect(stepsLeft(steps, s, const {'welcome', 'try'}), steps.length - 4);
      expect(stepsLeft(steps, null, const {}), steps.length);
    });

    test('completedSetup round-trips through json', () {
      const a = AppSettings(completedSetup: {'mic', 'welcome'});
      expect(AppSettings.fromJson(a.toJson()).completedSetup, {
        'mic',
        'welcome',
      });
      expect(AppSettings.fromJson(const {}).completedSetup, isEmpty);
    });
  });

  group('banner', () {
    testWidgets('counts the steps left and can be hidden', (tester) async {
      await tester.pumpWidget(
        host(
          const SetupBanner(),
          overrides: [
            ...baseOverrides(settings: const AppSettings(onboarded: true)),
            isAndroidProvider.overrideWithValue(true),
            setupStatusProvider.overrideWith(
              (ref) async => const SetupStatus(micGranted: true),
            ),
          ],
        ),
      );
      await pumpFor(tester, const Duration(milliseconds: 100));
      expect(find.text('Finish setup (6 steps left)'), findsOneWidget);
      await tester.tap(find.byTooltip('Hide setup reminder'));
      await pumpFor(tester, const Duration(milliseconds: 100));
      expect(find.textContaining('Finish setup'), findsNothing);
    });

    testWidgets('is absent before onboarding and once everything is done', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const SetupBanner(),
          overrides: [
            ...baseOverrides(settings: const AppSettings()),
            isAndroidProvider.overrideWithValue(true),
            setupStatusProvider.overrideWith(
              (ref) async => const SetupStatus(),
            ),
          ],
        ),
      );
      await pumpFor(tester, const Duration(milliseconds: 100));
      expect(find.textContaining('Finish setup'), findsNothing);
    });
  });
}
