// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/audio/audio_source.dart';
import 'package:ramble_voice/platform/android/android_services.dart';
import 'package:ramble_voice/platform/platform_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const audio = MethodChannel('ramble/audio');
  const system = MethodChannel('ramble/system');
  const ime = MethodChannel('ramble/ime');
  const pcm = EventChannel('ramble/audio/pcm');

  tearDown(() {
    messenger.setMockMethodCallHandler(audio, null);
    messenger.setMockMethodCallHandler(system, null);
    messenger.setMockMethodCallHandler(ime, null);
    messenger.setMockStreamHandler(pcm, null);
  });

  group('AndroidAudioSource', () {
    test('hasPermission reads the channel', () async {
      messenger.setMockMethodCallHandler(audio, (c) async => c.method == 'hasPermission' ? true : null);
      expect(await AndroidAudioSource().hasPermission(), isTrue);
    });

    test('requestPermission is false in the keyboard engine', () async {
      var asked = false;
      final source = AndroidAudioSource(canRequestPermission: false, requestMicrophone: () async => asked = true);
      expect(await source.requestPermission(), isFalse);
      expect(asked, isFalse);
    });

    test('requestPermission re-checks after prompting', () async {
      var granted = false;
      messenger.setMockMethodCallHandler(audio, (c) async => c.method == 'hasPermission' ? granted : null);
      final source = AndroidAudioSource(requestMicrophone: () async => granted = true);
      expect(await source.requestPermission(), isTrue);
    });

    test('start streams blocks and ends after stop', () async {
      final blocks = [
        Uint8List.fromList([1, 2]),
        Uint8List.fromList([3, 4]),
      ];
      MockStreamHandlerEventSink? sink;
      messenger.setMockStreamHandler(
        pcm,
        MockStreamHandler.inline(onListen: (args, events) => sink = events),
      );
      messenger.setMockMethodCallHandler(audio, (c) async {
        switch (c.method) {
          case 'start':
            scheduleMicrotask(() {
              for (final b in blocks) {
                sink!.success(b);
              }
            });
            return true;
          case 'stop':
            scheduleMicrotask(() => sink!.endOfStream());
            return null;
        }
        return null;
      });

      final capture = await AndroidAudioSource().start();
      final received = <Uint8List>[];
      final done = Completer<void>();
      capture.pcm.listen(received.add, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await capture.stop();
      await done.future.timeout(const Duration(seconds: 3));
      expect(received, blocks);
    });

    test('start maps a refusal to permissionDenied or deviceUnavailable', () async {
      var permitted = false;
      messenger.setMockStreamHandler(pcm, MockStreamHandler.inline(onListen: (args, events) {}));
      messenger.setMockMethodCallHandler(audio, (c) async => c.method == 'hasPermission' ? permitted : false);

      await expectLater(
        AndroidAudioSource().start(),
        throwsA(isA<AudioSourceException>().having((e) => e.error, 'error', AudioSourceError.permissionDenied)),
      );
      permitted = true;
      await expectLater(
        AndroidAudioSource().start(),
        throwsA(isA<AudioSourceException>().having((e) => e.error, 'error', AudioSourceError.deviceUnavailable)),
      );
    });
  });

  group('AndroidSystem', () {
    test('accentColor masks the signed ARGB int', () async {
      messenger.setMockMethodCallHandler(system, (c) async => c.method == 'accentColor' ? -16776961 : null);
      final color = await AndroidSystem().accentColor();
      expect(color!.toARGB32(), 0xFF0000FF);
    });

    test('accentColor is null when unavailable', () async {
      messenger.setMockMethodCallHandler(system, (c) async => null);
      expect(await AndroidSystem().accentColor(), isNull);
    });

    test('haptic, share and keyboard calls pass their arguments', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(system, (c) async {
        calls.add(c);
        return c.method == 'isKeyboardEnabled' ? true : null;
      });
      final s = AndroidSystem();
      await s.haptic('done');
      await s.share('hello');
      await s.openKeyboardSettings();
      expect(await s.isKeyboardEnabled(), isTrue);
      expect(calls.map((c) => c.method), ['haptic', 'share', 'openKeyboardSettings', 'isKeyboardEnabled']);
      expect(calls[0].arguments, 'done');
      expect(calls[1].arguments, 'hello');
    });
  });

  group('ImeBridge', () {
    test('commands reach the channel', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(ime, (c) async {
        calls.add(c);
        return true;
      });
      final bridge = ImeBridge();
      expect(await bridge.commitText('hi'), isTrue);
      await bridge.deleteBackward(count: 3);
      await bridge.openApp(ImeRoutes.models);
      expect(calls.map((c) => c.method), ['commitText', 'deleteBackward', 'openApp']);
      expect(calls[0].arguments, 'hi');
      expect(calls[1].arguments, 3);
      expect(calls[2].arguments, ImeRoutes.models);
      await bridge.dispose();
    });

    test('missing platform side returns false', () async {
      final bridge = ImeBridge();
      expect(await bridge.commitText('x'), isFalse);
      await bridge.dispose();
    });

    test('inputStarted updates current and the stream', () async {
      final bridge = ImeBridge();
      final next = bridge.inputStarted.first;
      await messenger.handlePlatformMessage(
        'ramble/ime',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('inputStarted', {
          'inputType': 1,
          'imeOptions': 3,
          'actionId': 3,
          'packageName': 'org.example',
          'isPassword': true,
        })),
        (_) {},
      );
      final info = await next;
      expect(info.action, ImeAction.search);
      expect(info.isPassword, isTrue);
      expect(bridge.current.packageName, 'org.example');
      await bridge.dispose();
    });

    test('release runs the callback', () async {
      final bridge = ImeBridge();
      var released = false;
      bridge.onRelease = () async => released = true;
      await messenger.handlePlatformMessage(
        'ramble/ime',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('release')),
        (_) {},
      );
      expect(released, isTrue);
      await bridge.dispose();
    });

    test('NO_ENTER_ACTION makes Enter a newline', () {
      const info = ImeInputInfo(actionId: 4, imeOptions: 0x40000004);
      expect(info.action, isNull);
    });
  });

  group('AndroidTextInserter', () {
    test('keyboard commits text', () async {
      messenger.setMockMethodCallHandler(ime, (c) async => true);
      final bridge = ImeBridge();
      final r = await AndroidTextInserter(bridge).insert('hello');
      expect(r.method, InsertMethod.typed);
      await bridge.dispose();
    });

    test('keyboard falls back to the clipboard without a field', () async {
      String? clip;
      messenger.setMockMethodCallHandler(ime, (c) async => false);
      messenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
        if (c.method == 'Clipboard.setData') clip = (c.arguments as Map)['text'] as String?;
        return null;
      });
      final bridge = ImeBridge();
      final r = await AndroidTextInserter(bridge).insert('hello');
      expect(r.method, InsertMethod.clipboardOnly);
      expect(clip, 'hello');
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      await bridge.dispose();
    });

    test('app copies to the clipboard', () async {
      String? clip;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
        if (c.method == 'Clipboard.setData') clip = (c.arguments as Map)['text'] as String?;
        return null;
      });
      final r = await AndroidTextInserter().insert('abc');
      expect(r.method, InsertMethod.clipboardOnly);
      expect(clip, 'abc');
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
  });

  test('AndroidNotifier records and emits notices', () async {
    final n = AndroidNotifier();
    final next = n.messages.first;
    await n.notify('T', 'B');
    expect((await next).title, 'T');
    expect(n.last!.body, 'B');
    await n.dispose();
  });
}
