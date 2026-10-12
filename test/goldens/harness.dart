// SPDX-License-Identifier: GPL-3.0-or-later

/// Offscreen screenshot harness: pumps real screens with fake providers at
/// phone and desktop sizes, light and dark, and writes PNGs for review.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3ETheme;
import 'package:material_ui/material_ui.dart';
import 'package:ramble_voice/app/providers.dart';
import 'package:ramble_voice/app/router.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_models.dart';
import 'package:ramble_voice/core/dictation/dictation_controller.dart';
import 'package:ramble_voice/core/history/history_db.dart';
import 'package:ramble_voice/core/models/model_catalog.dart';
import 'package:ramble_voice/core/models/model_downloader.dart';
import 'package:ramble_voice/core/models/model_downloads.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';
import 'package:ramble_voice/ime/ime_app.dart';
import 'package:ramble_voice/ime/keyboard_view.dart';
import 'package:ramble_voice/platform/android/ime_bridge.dart';
import 'package:ramble_voice/ui/screens/settings/gemini_section.dart';
import 'package:ramble_voice/ui/theme/app_theme.dart';
import 'package:ramble_voice/ui/screens/onboarding/setup_status.dart';
import 'package:ramble_voice/ui/util/app_label.dart';
import 'package:ramble_voice/ui/util/platform_flags.dart';

import '../ui/fakes.dart';

class Device {
  const Device(this.name, this.size, this.dpr, {this.android = false});
  final String name;
  final Size size;
  final double dpr;
  final bool android;
}

const phone = Device('phone', Size(412, 915), 1.5, android: true);
const desktop = Device('desktop', Size(1100, 760), 1, android: false);
const keyboard = Device('keyboard', Size(412, 248), 1.5, android: true);
const keyboardLarge = Device('keyboardLarge', Size(400, 285), 1.5, android: true);
const keyboardSmall = Device('keyboardSmall', Size(360, 248), 1.5, android: true);

Future<ByteData> _bytes(String path) async => ByteData.sublistView(await File(path).readAsBytes());

/// Roboto Flex from the repo and the Material icon font from the Flutter SDK,
/// so screenshots show real text and icons instead of test boxes.
Future<void> loadFonts() async {
  await (FontLoader('Roboto Flex')..addFont(_bytes('assets/fonts/RobotoFlex.ttf'))).load();
  final root = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/development/flutter';
  for (final path in [
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
  ]) {
    if (File(path).existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(_bytes(path))).load();
      return;
    }
  }
}

/// Download state per variant id.
class FakeDownloads implements ModelDownloads {
  FakeDownloads(this.status, {this.canPause = true});

  final Map<String, DownloadStatus> status;
  final bool canPause;

  @override
  bool get supportsPause => canPause;
  @override
  Stream<DownloadStatus> watch(GemmaVariant v) => const Stream.empty();
  @override
  DownloadStatus statusOf(GemmaVariant v) => status[v.id] ?? const NotDownloaded();
  @override
  Future<DownloadStatus> refresh(GemmaVariant v) async => statusOf(v);
  @override
  bool isActive(GemmaVariant v) => statusOf(v) is Downloading;
  @override
  Future<DownloadStatus> start(GemmaVariant v) async => statusOf(v);
  @override
  Future<void> delete(GemmaVariant v) async {}
  @override
  File finalFile(GemmaVariant v) => File('/nonexistent/${v.file}');
  @override
  Future<void> pause(GemmaVariant v) async {}
}

const _store = 3659530240;

DownloadStatus downloading(double f) => Downloading((_store * f).round(), _store);
const DownloadStatus downloaded = Downloaded('/x');

HistoryEntry entry(String id, String text, {int minutesAgo = 5, int seconds = 42, String engine = 'onDevice', bool fellBack = false}) =>
    HistoryEntry(
      id: id,
      createdAt: DateTime.now().subtract(Duration(minutes: minutesAgo)),
      durationMs: seconds * 1000,
      cleaned: text,
      engine: engine,
      fellBack: fellBack,
      stylePreset: 'casual',
    );

final sampleHistory = [
  entry('a', 'Can you move the design review to Thursday afternoon? I have a clash in the morning and I would like Priya to be there.', minutesAgo: 4, seconds: 18),
  entry('b', 'Pick up milk, eggs and the parcel from the post office before six.', minutesAgo: 95, seconds: 9, engine: 'gemini'),
  entry('c', 'Idea for the onboarding: show the microphone first, then ask which engine, and keep the tone choice for last.', minutesAgo: 60 * 26, seconds: 41),
  entry('d', 'Thanks for the update. I will review the draft tonight and send comments by Friday.', minutesAgo: 60 * 30, seconds: 14, engine: 'gemini', fellBack: true),
  entry('e', 'Reminder to renew the passport before the end of the month.', minutesAgo: 60 * 24 * 4, seconds: 7),
  entry('f', 'The key points from the call: budget is approved, launch is moved to March, and we need a second designer.', minutesAgo: 60 * 24 * 9, seconds: 52),
];

const sampleText = 'Can you move the design review to Thursday afternoon? I have a clash in the morning, and I would like Priya to be there.';

DictationOutcome outcome({CleanupFailure? fellBack}) => DictationOutcome(
      recordingId: 'rec1',
      text: sampleText,
      engine: EngineKind.onDevice,
      duration: const Duration(seconds: 18),
      createdAt: DateTime.now(),
      fallbackReason: fellBack,
    );

DictationListening listening({double level = 0.55, int seconds = 42, int limitSeconds = 600}) => DictationListening(
      elapsed: Duration(seconds: seconds),
      level: level,
      limit: Duration(seconds: limitSeconds),
      warnBefore: const Duration(seconds: 60),
    );

class _Pkg extends CurrentPackageNotifier {
  _Pkg(this.pkg);
  final String? pkg;
  @override
  String? build() => pkg;
}

/// Everything a scene can vary.
class Scene {
  const Scene({
    this.state = const DictationIdle(),
    this.settings = const AppSettings(onboarded: true, completedSetup: {'dismissed'}),
    this.readiness = const EngineReady(detail: 'GPU'),
    this.downloads = const {},
    this.pausable = true,
    this.history,
    this.keySource = KeySource.none,
    this.pending = const [],
    this.package,
    this.setup = const SetupStatus(micGranted: true, engineReady: true, keyboardEnabled: true, bubbleEnabled: true, hotkeyBound: true),
    this.manufacturer = 'google',
  });

  final DictationState state;
  final AppSettings settings;
  final EngineReadiness readiness;
  final Map<String, DownloadStatus> downloads;
  final bool pausable;
  final List<HistoryEntry>? history;
  final KeySource keySource;
  final List<String> pending;
  final String? package;
  final SetupStatus setup;
  final String manufacturer;
}

List<Override> overridesFor(Scene s, Device d) {
  final history = s.history ?? sampleHistory;
  final secrets = FakeSecrets()..source = s.keySource;
  return [
    ...baseOverrides(settings: s.settings, secrets: secrets),
    dictationStateProvider.overrideWith((ref) => Stream.value(s.state)),
    activeEngineReadinessProvider.overrideWith((ref) async => s.readiness),
    historyProvider.overrideWith((ref, query) => Stream.value([
          for (final e in history)
            if (query.isEmpty || e.cleaned.toLowerCase().contains(query.toLowerCase())) e,
        ])),
    pendingRecordingsProvider.overrideWith((ref) async => s.pending),
    modelDownloaderProvider.overrideWithValue(FakeDownloads(s.downloads, canPause: s.pausable)),
    geminiKeySourceProvider.overrideWith((ref) async => s.keySource),
    geminiModelsProvider.overrideWith((ref) async => const [
          GeminiModelInfo(id: 'gemini-3.8-pro', major: 3, minor: 8, preview: false, family: GeminiFamily.pro, freeTierUnavailable: true),
          GeminiModelInfo(id: 'gemini-3.8-flash', major: 3, minor: 8, preview: false, family: GeminiFamily.flash),
          GeminiModelInfo(id: 'gemini-3.7-flash', major: 3, minor: 7, preview: false, family: GeminiFamily.flash),
          GeminiModelInfo(id: 'gemini-3.1-flash-lite', major: 3, minor: 1, preview: false),
          GeminiModelInfo(id: 'gemini-3.2-flash-lite-preview', major: 3, minor: 2, preview: true),
        ]),
    verbatimProvider.overrideWith((ref, id) async => 'um can you uh move the design review to thursday afternoon i have a clash in the morning and i would like priya to be there'),
    setupStatusProvider.overrideWith((ref) async => s.setup),
    manufacturerProvider.overrideWith((ref) async => s.manufacturer),
    isAndroidProvider.overrideWithValue(d.android),
    isLinuxProvider.overrideWithValue(!d.android),
    currentPackageProvider.overrideWith(() => _Pkg(s.package)),
    appLabelProvider.overrideWith((ref, pkg) async => switch (pkg) {
          'com.google.android.gm' => 'Gmail',
          'com.example.notes' => 'Notes',
          _ => pkg,
        }),
    imeBridgeProvider.overrideWithValue(
      ImeBridge(channel: const MethodChannel('ramble/ime/golden'))..current = ImeInputInfo(packageName: s.package),
    ),
  ];
}

Widget _app(Widget home, Brightness b) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(brightness: Brightness.light),
      darkTheme: buildTheme(brightness: Brightness.dark),
      themeMode: b == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) => M3ETheme(data: buildM3eTheme(Theme.of(context)), child: child ?? const SizedBox.shrink()),
      home: home,
    );

void _size(WidgetTester tester, Device d) {
  tester.view.physicalSize = d.size * d.dpr;
  tester.view.devicePixelRatio = d.dpr;
  addTearDown(tester.view.reset);
  if (d.name == 'keyboardLarge') {
    tester.platformDispatcher.textScaleFactorTestValue = 1.15;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
  }
}

/// Pumps [home] (no router) as a screen.
Future<void> pumpWidgetScene(
  WidgetTester tester,
  Widget home, {
  required Scene scene,
  required Device device,
  required Brightness brightness,
  Duration settle = const Duration(milliseconds: 900),
}) async {
  _size(tester, device);
  await tester.pumpWidget(ProviderScope(overrides: overridesFor(scene, device), child: _app(home, brightness)));
  await _settle(tester, settle);
}

/// Pumps the real router at [location], so the shell, navigation and layout
/// switches are the ones users get.
Future<GoRouter> pumpRoute(
  WidgetTester tester,
  String location, {
  required Scene scene,
  required Device device,
  required Brightness brightness,
  Duration settle = const Duration(milliseconds: 900),
}) async {
  _size(tester, device);
  final router = buildRouter(onboarded: ValueNotifier<bool>(true));
  router.go(location);
  await tester.pumpWidget(ProviderScope(
    overrides: overridesFor(scene, device),
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(brightness: Brightness.light),
      darkTheme: buildTheme(brightness: Brightness.dark),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      routerConfig: router,
      builder: (context, child) => M3ETheme(data: buildM3eTheme(Theme.of(context)), child: child ?? const SizedBox.shrink()),
    ),
  ));
  await _settle(tester, settle);
  return router;
}

Future<void> _settle(WidgetTester tester, Duration d) async {
  await tester.pump();
  await tester.pump();
  var left = d;
  while (left > Duration.zero) {
    final step = left < const Duration(milliseconds: 100) ? left : const Duration(milliseconds: 100);
    await tester.pump(step);
    left -= step;
  }
}

Future<void> settle(WidgetTester tester, [Duration d = const Duration(milliseconds: 500)]) => _settle(tester, d);

/// Unmounts everything so no ticker or timer outlives the test.
Future<void> teardownScene(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 50));
}

/// Where PNGs go (gitignored; regenerate with --update-goldens).
String goldenPath(String name) => 'out/$name.png';

/// Writes a screenshot with `--update-goldens`. Otherwise it does nothing:
/// the images hold clock times and temp paths, so they are for reading, not
/// for pixel comparison, and a plain `flutter test` just proves every screen
/// builds.
Future<void> shoot(WidgetTester tester, String name, {Finder? of}) async {
  if (!autoUpdateGoldenFiles) return;
  await expectLater(of ?? find.byType(MaterialApp), matchesGoldenFile(goldenPath(name)));
}

KeyboardView keyboardView() => const KeyboardView();
