// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/platform/linux/linux_audio_source.dart';
import 'package:ramble_voice/platform/linux/tray.dart';
import 'package:ramble_voice/platform/platform_services.dart';

void main() {
  group('PcmAligner', () {
    test('never emits half samples and keeps all bytes', () {
      final a = PcmAligner();
      final out = <int>[];
      for (final chunk in [
        [1, 2, 3],
        [4, 5],
        [6],
        [7, 8, 9, 10],
      ]) {
        final r = a.push(Uint8List.fromList(chunk));
        if (r != null) {
          expect(r.length.isEven, isTrue);
          out.addAll(r);
        }
      }
      expect(out, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    });
  });

  group('tray', () {
    test('icon names per state', () {
      expect(trayIconFor(IndicatorState.idle), 'audio-input-microphone-symbolic');
      expect(trayIconFor(IndicatorState.listening), 'media-record-symbolic');
      expect(trayIconFor(IndicatorState.processing), 'emblem-synchronizing-symbolic');
    });

    test('dbusmenu layout has the three entries and a separator', () {
      final layout = buildMenuLayout(IndicatorState.idle);
      expect(layout.signature.value, '(ia{sv}av)');
      final children = layout.children[2].asArray();
      final labels = children.map((c) {
        final props = c.asVariant().asStruct()[1].asStringVariantDict();
        return props['label']?.asString() ?? props['type']!.asString();
      }).toList();
      expect(labels, ['Start dictation', 'Show window', 'separator', 'Quit']);
    });

    test('toggle label follows state', () {
      expect(trayToggleLabel(IndicatorState.listening), 'Stop dictation');
      expect(trayToggleLabel(IndicatorState.processing), 'Start dictation');
    });
  });
}
