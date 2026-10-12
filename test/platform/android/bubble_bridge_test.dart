// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/audio/audio_source.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/dictation/dictation_controller.dart';
import 'package:ramble_voice/platform/android/bubble_bridge.dart';
import 'package:ramble_voice/platform/platform_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('ramble/bubble');

  final calls = <MethodCall>[];
  Object? Function(MethodCall)? reply;

  setUp(() {
    calls.clear();
    reply = null;
    messenger.setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return reply?.call(c);
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> fromKotlin(String method, [Object? args]) async {
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  DictationOutcome outcome() => DictationOutcome(
        recordingId: 'r',
        text: 'hi',
        engine: EngineKind.onDevice,
        duration: const Duration(seconds: 1),
        createdAt: DateTime(2026),
      );

  group('bubbleStatusFor', () {
    const listening = DictationListening(
      elapsed: Duration.zero,
      level: 1.7,
      limit: Duration(minutes: 1),
      warnBefore: Duration(seconds: 10),
    );

    test('maps every state to a phase', () {
      expect(bubbleStatusFor(const DictationIdle()).phase, BubblePhase.idle);
      expect(bubbleStatusFor(const DictationStarting()).phase, BubblePhase.processing);
      expect(bubbleStatusFor(listening).phase, BubblePhase.listening);
      expect(bubbleStatusFor(const DictationProcessing(recordingId: 'r')).phase, BubblePhase.processing);
      expect(bubbleStatusFor(DictationDone(outcome())).phase, BubblePhase.done);
      expect(bubbleStatusFor(const DictationFailed(message: 'x')).phase, BubblePhase.error);
    });

    test('clamps the level', () => expect(bubbleStatusFor(listening).level, 1.0));

    test('microphone failures point at the app', () {
      final s = bubbleStatusFor(
        const DictationFailed(message: 'No microphone is available.', audioError: AudioSourceError.deviceUnavailable),
      );
      expect(s.message, contains('Open Ramble Voice'));
    });

    test('cleanup failures keep their message', () {
      expect(bubbleStatusFor(const DictationFailed(message: 'Rate limited.')).message, 'Rate limited.');
    });

    test('idle notice is carried', () {
      expect(bubbleStatusFor(const DictationIdle(notice: 'Nothing was recorded.')).message, 'Nothing was recorded.');
    });
  });

  group('BubbleBridge', () {
    test('routes commands from Kotlin', () async {
      final bridge = BubbleBridge(channel: channel);
      final seen = <String>[];
      bridge.onToggle = () async => seen.add('toggle');
      bridge.onStart = () async => seen.add('start');
      bridge.onStop = () async => seen.add('stop');
      bridge.onCancel = () async => seen.add('cancel');
      bridge.onRelease = () async => seen.add('release');
      for (final m in ['toggle', 'start', 'stop', 'cancel', 'release']) {
        await fromKotlin(m);
      }
      expect(seen, ['toggle', 'start', 'stop', 'cancel', 'release']);
      bridge.dispose();
    });

    test('stores the field context', () async {
      final bridge = BubbleBridge(channel: channel);
      await fromKotlin('context', {'packageName': 'org.example', 'isMultiline': true});
      expect(bridge.field.packageName, 'org.example');
      expect(bridge.field.isMultiline, isTrue);
      bridge.dispose();
    });

    test('sends ready and state', () async {
      final bridge = BubbleBridge(channel: channel);
      await bridge.ready();
      await bridge.sendState(const BubbleStatus(BubblePhase.listening, level: 0.5));
      expect(calls.map((c) => c.method), ['ready', 'state']);
      expect(calls[1].arguments, {'phase': 'listening', 'level': 0.5, 'message': null});
      bridge.dispose();
    });

    test('insert returns the native result and tolerates a missing service', () async {
      final bridge = BubbleBridge(channel: channel);
      reply = (_) => true;
      expect(await bridge.insert('hello'), isTrue);
      expect(calls.single.arguments, 'hello');
      messenger.setMockMethodCallHandler(channel, null);
      expect(await bridge.insert('hello'), isFalse);
      bridge.dispose();
    });
  });

  group('BubbleTextInserter', () {
    test('reports typed when Kotlin inserted', () async {
      reply = (_) => true;
      final r = await BubbleTextInserter(BubbleBridge(channel: channel)).insert('hi');
      expect(r.method, InsertMethod.typed);
      expect(r.delivered, isTrue);
    });

    test('reports clipboard only otherwise', () async {
      reply = (_) => false;
      final r = await BubbleTextInserter(BubbleBridge(channel: channel)).insert('hi');
      expect(r.method, InsertMethod.clipboardOnly);
      expect(r.delivered, isFalse);
    });
  });

  group('BubbleStateRelay', () {
    DictationListening level(double l) => DictationListening(
          elapsed: Duration.zero,
          level: l,
          limit: const Duration(minutes: 1),
          warnBefore: const Duration(seconds: 10),
        );

    test('drops duplicates and throttles level updates', () async {
      final states = StreamController<DictationState>.broadcast(sync: true);
      final clock = Stopwatch();
      final relay = BubbleStateRelay(states.stream, BubbleBridge(channel: channel), clock: clock);

      states
        ..add(level(0.1))
        ..add(level(0.1)) // duplicate
        ..add(level(0.2)); // too soon
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'state').length, 1);

      states.add(const DictationProcessing(recordingId: 'r')); // phase change is never throttled
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'state').length, 2);
      expect((calls.last.arguments as Map)['phase'], 'processing');

      await relay.dispose();
      await states.close();
    });
  });
}
