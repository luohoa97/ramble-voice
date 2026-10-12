// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/platform/android/ime_auto_start.dart';
import 'package:ramble_voice/platform/android/ime_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('ramble/ime/auto');

  late ImeBridge bridge;
  final log = <String>[];

  setUp(() {
    log.clear();
    bridge = ImeBridge(channel: channel);
  });

  tearDown(() => bridge.dispose());

  Future<void> fromKotlin(String method, [Object? args]) =>
      messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );

  ImeAutoStart make({Future<void> Function()? start}) => ImeAutoStart(
    bridge: bridge,
    onStart: start ?? () async => log.add('start'),
    onStop: () async => log.add('stop'),
  );

  test('ImeInputInfo parses autoStart and hold', () {
    final info = ImeInputInfo.fromMap({'autoStart': true, 'hold': true});
    expect(info.autoStart, isTrue);
    expect(info.hold, isTrue);
    expect(ImeInputInfo.fromMap({}).autoStart, isFalse);
  });

  test('ordinary inputStarted does nothing', () async {
    make();
    await fromKotlin('inputStarted', {'autoStart': false});
    await Future<void>.delayed(Duration.zero);
    expect(log, isEmpty);
  });

  test('tap handover starts and does not stop on release', () async {
    make();
    await fromKotlin('inputStarted', {'autoStart': true, 'hold': false});
    await fromKotlin('stopListening');
    await Future<void>.delayed(Duration.zero);
    expect(log, ['start']);
  });

  test('hold handover stops on release', () async {
    make();
    await fromKotlin('inputStarted', {'autoStart': true, 'hold': true});
    await Future<void>.delayed(Duration.zero);
    await fromKotlin('stopListening');
    await Future<void>.delayed(Duration.zero);
    expect(log, ['start', 'stop']);
  });

  test('release while the mic is still starting stops afterwards', () async {
    final gate = Completer<void>();
    make(
      start: () async {
        log.add('start');
        await gate.future;
      },
    );
    await fromKotlin('inputStarted', {'autoStart': true, 'hold': true});
    await fromKotlin('stopListening');
    await Future<void>.delayed(Duration.zero);
    expect(log, ['start']);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(log, ['start', 'stop']);
  });

  test('autoStart that arrived before attaching is honoured', () async {
    await fromKotlin('inputStarted', {'autoStart': true, 'hold': false});
    make();
    await Future<void>.delayed(Duration.zero);
    expect(log, ['start']);
  });
}
