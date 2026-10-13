// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/platform/android/bubble_setup.dart';

class _Env implements BubbleSetupEnv {
  bool mic = false;
  bool keyboard = false;
  bool bubble = false;
  bool battery = false;
  bool oem = false;
  int sdk = 36;
  final log = <String>[];

  @override
  Future<bool> hasMicrophone() async => mic;
  @override
  Future<bool> requestMicrophone() async {
    log.add('mic');
    mic = true;
    return true;
  }

  @override
  Future<bool> isKeyboardEnabled() async => keyboard;
  @override
  Future<void> openKeyboardSettings() async => log.add('keyboard');
  @override
  Future<bool> isBubbleEnabled() async => bubble;
  @override
  Future<void> openBubbleSettings() async => log.add('accessibility');
  @override
  Future<void> openAppDetails() async => log.add('appInfo');
  @override
  Future<bool> isIgnoringBattery() async => battery;
  @override
  Future<void> requestIgnoreBattery() async => log.add('battery');
  @override
  Future<bool> needsAutostartStep() async => oem;
  @override
  Future<void> openOemAutostart() async => log.add('autostart');
  @override
  Future<int> sdkInt() async => sdk;
}

void main() {
  test('only needed steps are listed', () async {
    final env = _Env()
      ..mic = true
      ..battery = true;
    final setup = BubbleSetup(env);
    await setup.start();
    expect(setup.steps, [BubbleSetupStep.keyboard, BubbleSetupStep.accessibility]);
    expect(setup.number, 1);
  });

  test('autostart step only on affected phones', () async {
    final env = _Env()..oem = true;
    final setup = BubbleSetup(env);
    await setup.start();
    expect(setup.steps.last, BubbleSetupStep.autostart);
  });

  test('walks through the steps and finishes', () async {
    final env = _Env();
    final setup = BubbleSetup(env);
    await setup.start();
    expect(setup.current, BubbleSetupStep.microphone);

    await setup.act(); // grants the mic
    expect(setup.current, BubbleSetupStep.keyboard);

    await setup.act();
    env.keyboard = true;
    await setup.refresh(); // app resumed
    expect(setup.current, BubbleSetupStep.accessibility);
    expect(setup.number, 3);

    await setup.act();
    env.bubble = true;
    await setup.refresh();
    expect(setup.current, BubbleSetupStep.battery);

    await setup.act();
    env.battery = true;
    await setup.refresh();
    expect(setup.finished, isTrue);
    expect(env.log, ['mic', 'keyboard', 'accessibility', 'battery']);
  });

  test('detects a restricted setting on Android 13+', () async {
    final env = _Env()
      ..mic = true
      ..keyboard = true
      ..battery = true;
    final setup = BubbleSetup(env);
    await setup.start();
    await setup.act();
    await setup.refresh(); // came back, still off
    expect(setup.restricted, isTrue);

    await setup.act(); // now opens App info
    expect(env.log.last, 'appInfo');

    await setup.retryAccessibility();
    expect(setup.restricted, isFalse);
    env.bubble = true;
    await setup.refresh();
    expect(setup.finished, isTrue);
  });

  test('no restricted hint before Android 13 or before the user tried', () async {
    final env = _Env()
      ..mic = true
      ..keyboard = true
      ..battery = true;
    final setup = BubbleSetup(env);
    await setup.start();
    await setup.refresh();
    expect(setup.restricted, isFalse);
    env.sdk = 32;
    await setup.act();
    await setup.refresh();
    expect(setup.restricted, isFalse);
  });

  test('skip moves past an unverifiable step', () async {
    final env = _Env()
      ..mic = true
      ..keyboard = true
      ..bubble = true
      ..battery = true
      ..oem = true;
    final setup = BubbleSetup(env);
    await setup.start();
    expect(setup.current, BubbleSetupStep.autostart);
    await setup.act();
    await setup.refresh();
    expect(setup.finished, isTrue);
  });
}
