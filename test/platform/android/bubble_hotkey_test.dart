// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';
import 'package:ramble_voice/platform/android/android_system.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('ramble/system');

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('settings', () {
    test('defaults: on, Caps Lock', () {
      const s = AppSettings();
      expect(s.physicalKeyHotkey, isTrue);
      expect(s.physicalKeyCode, BubbleHotkeys.capsLock);
    });

    test('round-trips through JSON', () {
      final s = const AppSettings().copyWith(physicalKeyHotkey: false, physicalKeyCode: BubbleHotkeys.rightCtrl);
      final back = AppSettings.fromJson(s.toJson());
      expect(back.physicalKeyHotkey, isFalse);
      expect(back.physicalKeyCode, BubbleHotkeys.rightCtrl);
    });

    test('old files without the fields get defaults', () {
      final s = AppSettings.fromJson(const {});
      expect(s.physicalKeyHotkey, isTrue);
      expect(s.physicalKeyCode, 115);
    });

    test('labels', () {
      expect(BubbleHotkeys.label(115), 'Caps Lock');
      expect(BubbleHotkeys.label(114), 'Right Ctrl');
      expect(BubbleHotkeys.label(131), 'Custom key (131)');
    });
  });

  group('channel', () {
    test('setBubbleConfig sends the hotkey', () async {
      Object? args;
      messenger.setMockMethodCallHandler(channel, (c) async {
        if (c.method == 'setBubbleConfig') args = c.arguments;
        return null;
      });
      await AndroidSystem().setBubbleConfig(
        blockedApps: ['a'],
        size: 'small',
        hotkeyEnabled: false,
        hotkeyCode: 114,
      );
      expect(args, {'blockedApps': ['a'], 'size': 'small', 'hotkeyEnabled': false, 'hotkeyCode': 114});
    });

    test('recordHotkey returns the key code, null when unavailable', () async {
      messenger.setMockMethodCallHandler(channel, (c) async => c.method == 'recordHotkey' ? 131 : null);
      expect(await AndroidSystem().recordHotkey(), 131);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await AndroidSystem().recordHotkey(), isNull);
    });
  });
}
