// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';
import 'package:ramble_voice/platform/linux/evdev_hotkey.dart';
import 'package:ramble_voice/platform/platform_services.dart';

const _proc = '''
I: Bus=0019 Vendor=0000 Product=0001 Version=0000
N: Name="Power Button"
P: Phys=PNP0C0C/button/input0
S: Sysfs=/devices/LNXSYSTM:00/LNXPWRBN:00/input/input0
U: Uniq=
H: Handlers=kbd event0 
B: PROP=0
B: EV=3
B: KEY=10000000000000 0

I: Bus=0011 Vendor=0001 Product=0001 Version=ab41
N: Name="AT Translated Set 2 keyboard"
P: Phys=isa0060/serio0/input0
S: Sysfs=/devices/platform/i8042/serio0/input/input3
U: Uniq=
H: Handlers=sysrq kbd leds event3 
B: PROP=0
B: EV=120013
B: KEY=402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe
B: MSC=10
B: LED=7

I: Bus=0003 Vendor=046d Product=c52b Version=0111
N: Name="Logitech USB Receiver Mouse"
P: Phys=usb-0000:00:14.0-2/input0
S: Sysfs=/devices/pci0000:00/0000:00:14.0/usb1/1-2/1-2:1.0/0003:046D:C52B.0001/input/input5
U: Uniq=
H: Handlers=mouse0 event5 
B: PROP=0
B: EV=17
B: KEY=ffff0000 0 0 0 0
B: REL=1c3
B: MSC=10
''';

Uint8List _event(int type, int code, int value, {int size = 24}) {
  final b = ByteData(size);
  b.setInt64(0, 1700000000, Endian.host); // tv_sec (only 8 of them for 32-bit)
  final at = size - 8;
  b.setUint16(at, type, Endian.host);
  b.setUint16(at + 2, code, Endian.host);
  b.setInt32(at + 4, value, Endian.host);
  return b.buffer.asUint8List();
}

void main() {
  group('parseInputDevices', () {
    test('finds only keyboards with Caps Lock', () {
      final devices = parseInputDevices(_proc, wordBits: 64);
      expect(devices.map((d) => d.eventPath), ['/dev/input/event3']);
      expect(devices.single.name, 'AT Translated Set 2 keyboard');
    });

    test('32-bit bitmap words', () {
      const text = '''
N: Name="kbd"
H: Handlers=kbd event7
B: EV=120013
B: KEY=0 0 0 0 4000000 0
''';
      // Bit 58 = word 1 (from the end) bit 26 = 0x4000000.
      expect(parseInputDevices(text, wordBits: 32).map((d) => d.eventPath), [
        '/dev/input/event7',
      ]);
      expect(parseInputDevices(text, wordBits: 64), isEmpty);
    });

    test('empty and garbage input', () {
      expect(parseInputDevices(''), isEmpty);
      expect(
        parseInputDevices('H: Handlers=event1\nB: EV=zz\nB: KEY=zz'),
        isEmpty,
      );
    });
  });

  group('InputEventParser', () {
    test('press, repeat, release; other keys and events are ignored', () {
      final p = InputEventParser(recordSize: 24);
      final out = p.add([
        ..._event(evKey, keyCapsLock, 1),
        ..._event(evKey, keyCapsLock, 2),
        ..._event(evKey, 30, 1), // 'a'
        ..._event(evKey, 30, 0),
        ..._event(0, 0, 0), // EV_SYN
        ..._event(4, 4, 58), // EV_MSC scancode
        ..._event(evKey, keyCapsLock, 0),
      ]);
      expect(out, [HotkeyPhase.pressed, HotkeyPhase.released]);
    });

    test('records split across chunks', () {
      final p = InputEventParser(recordSize: 24);
      final bytes = [
        ..._event(evKey, keyCapsLock, 1),
        ..._event(evKey, keyCapsLock, 0),
      ];
      final out = <HotkeyPhase>[];
      for (var i = 0; i < bytes.length; i += 7) {
        out.addAll(p.add(bytes.sublist(i, (i + 7).clamp(0, bytes.length))));
      }
      expect(out, [HotkeyPhase.pressed, HotkeyPhase.released]);
    });

    test('32-bit records', () {
      final p = InputEventParser(recordSize: 16);
      expect(p.add(_event(evKey, keyCapsLock, 1, size: 16)), [
        HotkeyPhase.pressed,
      ]);
    });
  });

  group('EvdevHotkey', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('evdev'));
    tearDown(() => dir.deleteSync(recursive: true));

    File procFile() =>
        File('${dir.path}/devices')
          ..writeAsStringSync(_proc.replaceAll('event3', 'event3'));

    test('emits events and collapses duplicates', () async {
      final ctrl = StreamController<List<int>>();
      final hk = EvdevHotkey(
        devicesFile: procFile().path,
        rescan: const Duration(hours: 1),
        openDevice: (_) async => ctrl.stream,
      );
      final status = await hk.start();
      expect(status.readable, isTrue);
      final seen = <HotkeyPhase>[];
      hk.events.listen((e) => seen.add(e.phase));
      ctrl.add(_event(evKey, keyCapsLock, 1));
      ctrl.add(_event(evKey, keyCapsLock, 0));
      await Future<void>.delayed(Duration.zero);
      expect(seen, [HotkeyPhase.pressed, HotkeyPhase.released]);
      await hk.dispose();
      await ctrl.close();
    });

    test('EACCES reports permission denied', () async {
      final hk = EvdevHotkey(
        devicesFile: procFile().path,
        rescan: const Duration(hours: 1),
        openDevice: (p) async => throw FileSystemException(
          'denied',
          p,
          const OSError('Permission denied', 13),
        ),
      );
      final status = await hk.start();
      expect(status.readable, isFalse);
      expect(status.permissionDenied, isTrue);
      await hk.dispose();
    });
  });

  group('XkbCapsRemap', () {
    test('parse and format', () {
      expect(XkbCapsRemap.parse('@as []\n'), isEmpty);
      expect(XkbCapsRemap.parse("['ctrl:swap_lalt_lctl', 'compose:ralt']"), [
        'ctrl:swap_lalt_lctl',
        'compose:ralt',
      ]);
      expect(XkbCapsRemap.format([]), '@as []');
      expect(XkbCapsRemap.format(['a:b', 'c:d']), "['a:b', 'c:d']");
    });

    test('adds caps:none and drops other caps:*', () {
      expect(XkbCapsRemap.withCapsNone(['caps:escape', 'compose:ralt']), [
        'compose:ralt',
        'caps:none',
      ]);
      expect(XkbCapsRemap.withCapsNone(['caps:none']), ['caps:none']);
    });

    test('removes only caps:none', () {
      expect(XkbCapsRemap.withoutCapsNone(['caps:none', 'compose:ralt']), [
        'compose:ralt',
      ]);
    });

    test('skips gsettings outside GNOME, writes on GNOME', () async {
      final calls = <List<String>>[];
      Future<ProcessResult> run(String exe, List<String> args) async {
        calls.add(args);
        return ProcessResult(
          0,
          0,
          args.first == 'get' ? "['compose:ralt']\n" : '',
          '',
        );
      }

      expect(
        await XkbCapsRemap(
          environment: {'XDG_CURRENT_DESKTOP': 'KDE'},
          run: run,
        ).setCapsDisabled(true),
        isFalse,
      );
      expect(calls, isEmpty);

      final gnome = XkbCapsRemap(
        environment: {'XDG_CURRENT_DESKTOP': 'ubuntu:GNOME'},
        run: run,
      );
      expect(await gnome.setCapsDisabled(true), isTrue);
      expect(calls.last, [
        'set',
        'org.gnome.desktop.input-sources',
        'xkb-options',
        "['compose:ralt', 'caps:none']",
      ]);
    });
  });

  test('hotkeyKey setting defaults to capslock and round-trips', () {
    expect(const AppSettings().hotkeyKey, 'capslock');
    final s = const AppSettings().copyWith(hotkeyKey: 'portal');
    expect(AppSettings.fromJson(s.toJson()).hotkeyKey, 'portal');
    expect(AppSettings.fromJson(<String, Object?>{}).hotkeyKey, 'capslock');
  });
}
