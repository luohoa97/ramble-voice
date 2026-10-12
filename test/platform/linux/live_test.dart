// SPDX-License-Identifier: GPL-3.0-or-later

// Live checks against the real session. Skipped unless RAMBLE_LIVE=1:
//   RAMBLE_LIVE=1 RAMBLE_CAPTURE_LIB=/path/libramble_capture.so tool/fl flutter test test/platform/linux/live_test.dart
// Set RAMBLE_LIVE_SHORTCUTS=1 to also create (and close) a GlobalShortcuts
// session, which may show a desktop dialog.
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';
import 'package:ramble_voice/platform/linux/linux_audio_source.dart';
import 'package:ramble_voice/platform/linux/linux_environment.dart';
import 'package:ramble_voice/platform/linux/portal/global_shortcuts.dart';
import 'package:ramble_voice/platform/linux/portal/notifications.dart';
import 'package:ramble_voice/platform/linux/portal/portal.dart';
import 'package:ramble_voice/platform/linux/portal/settings.dart';
import 'package:ramble_voice/platform/linux/secret_service_store.dart';

void main() {
  final live = Platform.environment['RAMBLE_LIVE'] == '1';
  final skip = live ? null : 'set RAMBLE_LIVE=1';
  late DBusClient bus;
  late PortalClient portal;

  setUpAll(() {
    if (!live) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    bus = DBusClient.session();
    portal = PortalClient(bus);
  });

  Future<void> register() => portal.registerHostApp(rambleAppId);
  tearDownAll(() async {
    if (live) await bus.close();
  });

  test('environment and portal versions', () async {
    final env = await LinuxEnvironment.detect(portal: portal);
    // ignore: avoid_print
    print(env.describe());
    expect(env.portalVersions.keys, isNotEmpty);
  }, skip: skip);

  test('settings portal', () async {
    final s = PortalSettings(portal);
    // ignore: avoid_print
    print('accent=${await s.accentColor()} scheme=${await s.colorScheme()}');
  }, skip: skip);

  test('notification post and remove', () async {
    final n = PortalNotifier(portal);
    await n.post('ramble-live-test', 'Ramble Voice test', 'Live notification check', persistent: true);
    await Future<void>.delayed(const Duration(seconds: 2));
    await n.post('ramble-live-test', 'Ramble Voice test', 'Replaced in place', persistent: true);
    await Future<void>.delayed(const Duration(seconds: 1));
    await n.remove('ramble-live-test');
    // ignore: avoid_print
    print('notification backend: ${n.backend}');
  }, skip: skip);

  test('secret service round trip', () async {
    final tmp = Directory.systemTemp.createTempSync('ramble-secret');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final store = SecretServiceStore(bus,
        fallbackFile: File('${tmp.path}/key'), secretKey: 'ramble-test-${DateTime.now().millisecondsSinceEpoch}', environment: const {});
    await store.writeGeminiKey('test-key-123');
    // ignore: avoid_print
    print('describe: ${await store.describe()}');
    expect(await store.readGeminiKey(), 'test-key-123');
    expect(await store.geminiKeySource(), KeySource.secureStorage);
    await store.deleteGeminiKey();
    expect(await store.readGeminiKey(), isNull);
    expect(await store.geminiKeySource(), KeySource.none);
  }, skip: skip);

  test('environment variable wins', () async {
    final tmp = Directory.systemTemp.createTempSync('ramble-secret');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final store = SecretServiceStore(bus, fallbackFile: File('${tmp.path}/key'), environment: const {'GEMINI_API_KEY': 'envkey'});
    expect(await store.readGeminiKey(), 'envkey');
    expect(await store.geminiKeySource(), KeySource.environment);
  }, skip: skip);

  test('file fallback when Secret Service is unavailable', () async {
    final tmp = Directory.systemTemp.createTempSync('ramble-secret');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final dead = DBusClient(DBusAddress.unix(path: '/nonexistent/bus'));
    addTearDown(dead.close);
    final store = SecretServiceStore(dead, fallbackFile: File('${tmp.path}/key'), environment: const {});
    await store.writeGeminiKey('abc');
    expect(await store.readGeminiKey(), 'abc');
    expect(File('${tmp.path}/key').statSync().mode & 0x1ff, 384); // 0600
    expect(await store.describe(), contains('not encrypted'));
    await store.deleteGeminiKey();
    expect(await store.readGeminiKey(), isNull);
  }, skip: skip);

  test('audio source records bytes', () async {
    final src = LinuxAudioSource();
    final cap = await src.start();
    var bytes = 0;
    final sub = cap.pcm.listen((b) => bytes += b.length);
    await Future<void>.delayed(const Duration(seconds: 2));
    await cap.stop();
    await sub.cancel();
    // ignore: avoid_print
    print('backend=${src.backendName} lib=${src.nativeLibraryPath} bytes=$bytes');
    expect(bytes, greaterThan(16000));
  }, skip: skip);

  test('audio source falls back to pw-record', () async {
    final src = LinuxAudioSource(allowNative: false);
    final cap = await src.start();
    var bytes = 0;
    final sub = cap.pcm.listen((b) => bytes += b.length);
    await Future<void>.delayed(const Duration(seconds: 1));
    await cap.stop();
    await sub.cancel();
    // ignore: avoid_print
    print('backend=${src.backendName} lib=${src.nativeLibraryPath} bytes=$bytes');
    expect(bytes, greaterThan(8000));
  }, skip: skip);

  test('global shortcuts session', () async {
    await register();
    final env = await LinuxEnvironment.detect(portal: portal);
    final svc = PortalHotkeyService(portal, env);
    final status = await svc.bind();
    // ignore: avoid_print
    print('hotkey: ${status.backend} ${status.trigger} ${status.message}');
    await svc.dispose();
  }, skip: live && Platform.environment['RAMBLE_LIVE_SHORTCUTS'] == '1' ? null : 'set RAMBLE_LIVE=1 RAMBLE_LIVE_SHORTCUTS=1');
}
