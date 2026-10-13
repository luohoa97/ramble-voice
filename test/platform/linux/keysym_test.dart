// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/platform/linux/portal/remote_desktop.dart';
import 'package:ramble_voice/platform/linux/portal/settings.dart';

void main() {
  group('Keysyms', () {
    test('ASCII maps directly', () {
      expect(Keysyms.forText('Az 9~'), [0x41, 0x7a, 0x20, 0x39, 0x7e]);
    });

    test('newline and tab use named keys, CRLF is one Enter', () {
      expect(Keysyms.forText('a\nb\tc'), [0x61, 0xff0d, 0x62, 0xff09, 0x63]);
      expect(Keysyms.forText('a\r\nb'), [0x61, 0xff0d, 0x62]);
      expect(Keysyms.forText('a\rb'), [0x61, 0xff0d, 0x62]);
    });

    test(
      'Latin-1 maps 1:1, other code points use the Unicode keysym range',
      () {
        expect(Keysyms.forText('é'), [0xe9]);
        expect(Keysyms.forText('€'), [0x01000000 + 0x20ac]);
        expect(Keysyms.forText('日本'), [
          0x01000000 + 0x65e5,
          0x01000000 + 0x672c,
        ]);
      },
    );

    test('non-BMP characters are one keysym, not two surrogates', () {
      expect(Keysyms.forText('😀'), [0x01000000 + 0x1f600]);
    });

    test('control characters are dropped', () {
      expect(Keysyms.forText('a\u0000\u001b\u007fb'), [0x61, 0x62]);
    });

    test('text that looks like commands is typed verbatim', () {
      expect(Keysyms.forText('\$(rm -rf /)').length, 11);
    });
  });

  group('PortalSettings.parseAccent', () {
    test('reads (ddd) in 0..1', () {
      final c = PortalSettings.parseAccent(
        DBusStruct([DBusDouble(1), DBusDouble(0), DBusDouble(0.5)]),
      );
      expect(c, isNotNull);
      expect(c!.r, 1.0);
      expect(c.g, 0.0);
      expect(c.b, closeTo(0.5, 1e-9));
    });

    test('rejects unset sentinel and malformed values', () {
      expect(
        PortalSettings.parseAccent(
          DBusStruct([DBusDouble(-1), DBusDouble(-1), DBusDouble(-1)]),
        ),
        isNull,
      );
      expect(PortalSettings.parseAccent(DBusString('x')), isNull);
      expect(PortalSettings.parseAccent(null), isNull);
    });
  });
}
