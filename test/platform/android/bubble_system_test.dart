// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/platform/android/android_system.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('ramble/system');
  final calls = <String>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (c) async {
      calls.add(c.method);
      return switch (c.method) {
        'isIgnoringBattery' => true,
        'manufacturer' => 'HONOR',
        _ => null,
      };
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('battery and manufacturer queries', () async {
    final system = AndroidSystem();
    expect(await system.isIgnoringBattery(), isTrue);
    expect(await system.manufacturer(), 'honor');
  });

  test('actions reach the channel', () async {
    final system = AndroidSystem();
    await system.requestIgnoreBattery();
    await system.openOemAutostart();
    await system.forgetBubble();
    expect(calls, ['requestIgnoreBattery', 'openOemAutostart', 'forgetBubble']);
  });

  test('missing plugin is tolerated', () async {
    messenger.setMockMethodCallHandler(channel, null);
    final system = AndroidSystem();
    expect(await system.isIgnoringBattery(), isFalse);
    expect(await system.manufacturer(), '');
    await system.openOemAutostart();
  });
}
