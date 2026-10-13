// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ramble_voice/app/providers.dart';
import 'package:ramble_voice/core/audio/audio_source.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';
import 'package:ramble_voice/platform/platform_services.dart';
import 'package:ramble_voice/ui/theme/app_theme.dart';

class FakeAudio implements AudioSource {
  @override
  String get backendName => 'fake';
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<AudioCapture> start() async => _Capture();
}

class _Capture implements AudioCapture {
  @override
  Stream<Uint8List> get pcm => const Stream.empty();
  @override
  Future<void> stop() async {}
}

class FakeSecrets implements SecretStore {
  KeySource source = KeySource.none;
  @override
  Future<void> deleteGeminiKey() async => source = KeySource.none;
  @override
  Future<KeySource> geminiKeySource() async => source;
  @override
  Future<String?> readGeminiKey() async => null;
  @override
  Future<void> writeGeminiKey(String key) async =>
      source = KeySource.secureStorage;
}

class FakeInserter implements TextInserter {
  @override
  Future<void> copy(String text) async {}
  @override
  Future<String> describe() async => 'Fake inserter';
  @override
  Future<InsertResult> insert(String text) async =>
      const InsertResult(InsertMethod.none);
}

class FakeNotifier implements SystemNotifier {
  @override
  Future<void> notify(String title, String body) async {}
}

PlatformServices fakeServices({SecretStore? secrets}) => PlatformServices(
  audio: FakeAudio(),
  secrets: secrets ?? FakeSecrets(),
  inserter: FakeInserter(),
  notifier: FakeNotifier(),
);

List<Override> baseOverrides({
  AppSettings settings = const AppSettings(onboarded: true),
  SecretStore? secrets,
}) => [
  platformServicesProvider.overrideWithValue(fakeServices(secrets: secrets)),
  appPathsProvider.overrideWithValue(
    AppPaths(support: Directory.systemTemp.createTempSync('ramble_ui_test')),
  ),
  initialSettingsProvider.overrideWithValue(settings),
];

Widget host(
  Widget child, {
  List<Override> overrides = const [],
  Brightness brightness = Brightness.light,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: buildTheme(brightness: brightness),
      home: Scaffold(body: child),
    ),
  );
}

/// Advances time in frame-sized steps. Prefer this to `pumpAndSettle`, which
/// never returns while an animation repeats.
Future<void> pumpFor(
  WidgetTester tester, [
  Duration total = const Duration(milliseconds: 400),
]) async {
  var left = total;
  const step = Duration(milliseconds: 16);
  while (left > Duration.zero) {
    await tester.pump(left < step ? left : step);
    left -= step;
  }
}
