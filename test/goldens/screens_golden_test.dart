// SPDX-License-Identifier: GPL-3.0-or-later

@Tags(['golden'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ramble_voice/core/audio/audio_source.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/dictation/dictation_controller.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';
import 'package:ramble_voice/core/style/style_profile.dart';
import 'package:ramble_voice/ui/screens/onboarding_screen.dart';
import 'package:ramble_voice/ui/screens/onboarding/setup_status.dart';
import 'package:ramble_voice/ui/widgets/engine_chip.dart';

import 'harness.dart';

const _gemini = AppSettings(onboarded: true, completedSetup: {'dismissed'}, engine: EngineKind.gemini);
const _custom = AppSettings(
  onboarded: true,
  completedSetup: {'dismissed'},
  style: StyleProfile(preset: StylePreset.professional, customInstructions: 'Keep British spelling.'),
);

void main() {
  setUpAll(loadFonts);

  final modes = {'light': Brightness.light, 'dark': Brightness.dark};

  void routeScene(
    String name,
    Device device,
    String location,
    Scene scene, {
    Future<void> Function(WidgetTester)? act,
  }) {
    for (final m in modes.entries) {
      testWidgets('$name ${device.name} ${m.key}', (tester) async {
        await pumpRoute(tester, location, scene: scene, device: device, brightness: m.value);
        await act?.call(tester);
        await shoot(tester, '${name}_${device.name}_${m.key}');
        await teardownScene(tester);
      });
    }
  }

  void widgetScene(
    String name,
    Device device,
    Widget Function() home,
    Scene scene, {
    Future<void> Function(WidgetTester)? act,
    Duration settleFor = const Duration(milliseconds: 900),
  }) {
    for (final m in modes.entries) {
      testWidgets('$name ${device.name} ${m.key}', (tester) async {
        await pumpWidgetScene(tester, home(), scene: scene, device: device, brightness: m.value, settle: settleFor);
        await act?.call(tester);
        await shoot(tester, '${name}_${device.name}_${m.key}');
        await teardownScene(tester);
      });
    }
  }

  // ---- Record ----
  for (final d in [phone, desktop]) {
    routeScene('record_idle', d, '/', const Scene());
    routeScene('record_listening', d, '/', Scene(state: listening()));
    routeScene('record_near_limit', d, '/', Scene(state: listening(seconds: 560, level: 0.2)));
    routeScene('record_processing', d, '/', const Scene(state: DictationProcessing(recordingId: 'r')));
    routeScene('record_done', d, '/', Scene(state: DictationDone(outcome())));
    routeScene(
      'record_done_fallback',
      d,
      '/',
      Scene(
        state: DictationDone(outcome(fellBack: const CleanupFailure(CleanupFailureKind.rateLimited, 'Rate limited'))),
        settings: _gemini,
      ),
    );
    routeScene(
      'record_error_key',
      d,
      '/',
      Scene(
        settings: _gemini,
        state: const DictationFailed(
          message: 'Add your Gemini API key to use cloud cleanup.',
          kind: CleanupFailureKind.missingApiKey,
          recordingId: 'rec1',
        ),
        readiness: const EngineNotReady(CleanupFailureKind.missingApiKey, 'x'),
      ),
    );
    routeScene(
      'record_error_mic',
      d,
      '/',
      const Scene(
        state: DictationFailed(message: 'Microphone access is off.', audioError: AudioSourceError.permissionDenied),
      ),
    );
    routeScene('record_pending', d, '/', const Scene(pending: ['old1']));
    routeScene('record_model_missing', d, '/', const Scene(
      readiness: EngineNotReady(CleanupFailureKind.modelNotDownloaded, 'x'),
    ));
    routeScene('record_custom_style', d, '/', const Scene(settings: _custom));
  }

  // ---- Engine picker ----
  for (final d in [phone, desktop]) {
    routeScene(
      'picker_ondevice',
      d,
      '/',
      Scene(downloads: {'gemma-4-e4b': downloaded, 'gemma-4-e2b': downloading(0.41)}),
      act: (t) async {
        await t.tap(find.byType(EngineChip));
        await settle(t);
      },
    );
    routeScene(
      'picker_gemini',
      d,
      '/',
      const Scene(settings: _gemini, keySource: KeySource.secureStorage, readiness: EngineReady(detail: 'gemini-3.1-flash-lite')),
      act: (t) async {
        await t.tap(find.byType(EngineChip));
        await settle(t);
      },
    );
  }

  // ---- History ----
  routeScene('history', phone, '/history', const Scene());
  routeScene('history_empty', phone, '/history', const Scene(history: []));
  routeScene('history_detail', phone, '/history', const Scene(), act: (t) async {
    await t.tap(find.textContaining('design review').first);
    await settle(t);
  });
  routeScene('history_detail', desktop, '/', const Scene(), act: (t) async {
    await t.tap(find.textContaining('Pick up milk').first);
    await settle(t);
  });

  // ---- Settings ----
  for (final d in [phone, desktop]) {
    routeScene('settings_ondevice_download', d, '/settings', Scene(downloads: {'gemma-4-e4b': downloading(0.41)}));
    routeScene('settings_ondevice_ready', d, '/settings', Scene(downloads: {'gemma-4-e4b': downloaded}));
    routeScene('settings_gemini', d, '/settings', const Scene(settings: _gemini, keySource: KeySource.secureStorage));
    routeScene('settings_gemini_nokey', d, '/settings', const Scene(settings: _gemini));
  }
  routeScene(
    'settings_lower',
    phone,
    '/settings',
    const Scene(settings: AppSettings(onboarded: true, completedSetup: {'dismissed'}, appStyles: {'com.example.notes': StylePreset.notes, 'com.google.android.gm': StylePreset.casual})),
    act: (t) async {
      await t.drag(find.byType(Scrollable).first, const Offset(0, -1100));
      await settle(t);
    },
  );
  routeScene(
    'settings_lower2',
    phone,
    '/settings',
    const Scene(),
    act: (t) async {
      await t.drag(find.byType(Scrollable).first, const Offset(0, -2600));
      await settle(t);
    },
  );

  // ---- Setup guide ----
  const none = SetupStatus();
  const mid = SetupStatus(micGranted: true);
  final androidSteps = <(String, int, SetupStatus)>[
    ('welcome', 0, none),
    ('mic', 1, none),
    ('mic_done', 1, mid),
    ('engine', 2, mid),
    ('keyboard', 3, SetupStatus(micGranted: true, engineReady: true)),
    ('bubble', 4, SetupStatus(micGranted: true, engineReady: true, keyboardEnabled: true)),
    ('try', 5, SetupStatus(micGranted: true, engineReady: true, keyboardEnabled: true, bubbleEnabled: true)),
    ('tips', 6, SetupStatus(micGranted: true, engineReady: true, keyboardEnabled: true, bubbleEnabled: true)),
  ];
  for (final (name, step, status) in androidSteps) {
    widgetScene(
      'setup_$name',
      phone,
      () => OnboardingScreen(initialStep: step),
      Scene(
        settings: const AppSettings(),
        setup: status,
        manufacturer: name == 'bubble' ? 'honor' : 'google',
        downloads: {'gemma-4-e4b': downloading(0.12)},
      ),
    );
  }
  widgetScene('setup_engine_gemini', phone, () => const OnboardingScreen(initialStep: 2),
      const Scene(settings: _gemini, setup: mid));
  for (var i = 0; i < 4; i++) {
    widgetScene('setup_linux$i', desktop, () => OnboardingScreen(initialStep: i), const Scene(settings: AppSettings(), setup: none));
  }
  widgetScene('setup_welcome', desktop, () => const OnboardingScreen(), const Scene(settings: AppSettings(), setup: none));
  routeScene('record_setup_banner', phone, '/', const Scene(settings: AppSettings(onboarded: true), setup: SetupStatus(micGranted: true)));

  // ---- Keyboard ----
  const gmail = 'com.google.android.gm';
  for (final d in [keyboard, keyboardLarge, keyboardSmall]) {
    widgetScene('kb_idle', d, keyboardView, const Scene(package: gmail));
    widgetScene('kb_listening', d, keyboardView, Scene(package: gmail, state: listening()));
    widgetScene('kb_paused', d, keyboardView, Scene(package: gmail, state: DictationListening(
      elapsed: const Duration(seconds: 42), level: 0, limit: const Duration(minutes: 10), warnBefore: const Duration(seconds: 60), paused: true)));
    widgetScene('kb_done', d, keyboardView, Scene(package: gmail, state: DictationDone(outcome())));
    widgetScene('kb_error', d, keyboardView, const Scene(package: gmail, state: DictationFailed(message: 'Add your Gemini API key.', kind: CleanupFailureKind.missingApiKey)));
    widgetScene('kb_discarded', d, keyboardView, const Scene(package: gmail, state: DictationIdle(notice: 'Recording discarded.', discardedId: 'x')));
  }
  widgetScene('keyboard_idle', keyboard, keyboardView, const Scene(package: gmail));
  widgetScene('keyboard_listening', keyboard, keyboardView, Scene(package: gmail, state: listening()));
  widgetScene('keyboard_near_limit', keyboard, keyboardView, Scene(package: gmail, state: listening(seconds: 570, level: 0.3)));
  widgetScene('keyboard_processing', keyboard, keyboardView, const Scene(package: gmail, state: DictationProcessing(recordingId: 'r')));
  widgetScene('keyboard_done', keyboard, keyboardView, Scene(package: gmail, state: DictationDone(outcome())));
  widgetScene(
    'keyboard_error',
    keyboard,
    keyboardView,
    const Scene(
      package: gmail,
      state: DictationFailed(message: 'Add your Gemini API key.', kind: CleanupFailureKind.missingApiKey),
    ),
  );
  widgetScene('keyboard_custom_unknown_app', keyboard, keyboardView, const Scene(settings: _custom));
}
