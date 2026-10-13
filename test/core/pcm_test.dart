// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/audio/pcm.dart';

import '../fakes/pcm_fixtures.dart';

void main() {
  group('Pcm', () {
    test('durationOf and bytesFor are inverse for whole seconds', () {
      expect(Pcm.durationOf(Pcm.bytesPerSecond), const Duration(seconds: 1));
      expect(
        Pcm.durationOf(Pcm.bytesPerSecond * 90),
        const Duration(seconds: 90),
      );
      expect(Pcm.bytesFor(const Duration(seconds: 1)), 32000);
      expect(Pcm.bytesFor(const Duration(milliseconds: 30)), 960);
      expect(Pcm.durationOf(0), Duration.zero);
    });

    test('bytesFor is sample aligned', () {
      expect(Pcm.bytesFor(const Duration(microseconds: 100)) % 2, 0);
      expect(Pcm.bytesFor(const Duration(microseconds: 62)), 0);
    });

    test('durationOf ignores a trailing odd byte', () {
      expect(Pcm.durationOf(33), Pcm.durationOf(32));
    });

    test('samples decodes little endian', () {
      final bytes = Uint8List.fromList([
        0x01,
        0x00,
        0xFF,
        0xFF,
        0x00,
        0x80,
        0xFF,
        0x7F,
      ]);
      expect(Pcm.samples(bytes), [1, -1, -32768, 32767]);
    });

    test('samples handles unaligned views and odd lengths', () {
      final backing = Uint8List.fromList([0, 0x34, 0x12, 0x78, 0x56, 0x99]);
      final view = Uint8List.sublistView(backing, 1); // offset 1, 5 bytes
      expect(Pcm.samples(view), [0x1234, 0x5678]);
    });

    test('level: silence and empty are 0', () {
      expect(Pcm.level(silencePcm(const Duration(milliseconds: 100))), 0);
      expect(Pcm.level(Uint8List(0)), 0);
    });

    test('level: full scale is about 1 and louder is higher', () {
      final loud = Pcm.level(
        tonePcm(const Duration(milliseconds: 200), amplitude: 1.0),
      );
      final quiet = Pcm.level(
        tonePcm(const Duration(milliseconds: 200), amplitude: 0.01),
      );
      expect(loud, closeTo(1.0, 0.06));
      expect(quiet, inInclusiveRange(0.0, 1.0));
      expect(quiet, lessThan(loud));
    });

    test('level: below -60 dBFS is 0', () {
      final whisper = Uint8List(2000);
      final d = ByteData.sublistView(whisper);
      for (var i = 0; i < 1000; i++) {
        d.setInt16(i * 2, i.isEven ? 10 : -10, Endian.little); // ~ -70 dBFS
      }
      expect(Pcm.level(whisper), 0);
    });
  });

  group('WavEncoder', () {
    test('writes a canonical 44-byte header', () {
      final pcm = tonePcm(const Duration(milliseconds: 100));
      final wav = WavEncoder.encode(pcm);
      final d = ByteData.sublistView(wav);
      String tag(int o) => String.fromCharCodes(wav.sublist(o, o + 4));

      expect(wav.length, 44 + pcm.length);
      expect(tag(0), 'RIFF');
      expect(d.getUint32(4, Endian.little), 36 + pcm.length);
      expect(tag(8), 'WAVE');
      expect(tag(12), 'fmt ');
      expect(d.getUint32(16, Endian.little), 16);
      expect(d.getUint16(20, Endian.little), 1, reason: 'PCM format tag');
      expect(d.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(d.getUint32(24, Endian.little), 16000);
      expect(d.getUint32(28, Endian.little), 32000, reason: 'byte rate');
      expect(d.getUint16(32, Endian.little), 2, reason: 'block align');
      expect(d.getUint16(34, Endian.little), 16);
      expect(tag(36), 'data');
      expect(d.getUint32(40, Endian.little), pcm.length);
    });

    test('empty input yields a header only', () {
      final wav = WavEncoder.encode(Uint8List(0));
      expect(wav.length, 44);
      expect(WavEncoder.decode(wav), isEmpty);
    });

    test('drops a trailing odd byte', () {
      final wav = WavEncoder.encode(Uint8List.fromList([1, 2, 3]));
      expect(wav.length, 46);
      expect(WavEncoder.decode(wav), [1, 2]);
    });

    test('decode round trips', () {
      final pcm = tonePcm(const Duration(milliseconds: 250), amplitude: 0.7);
      expect(WavEncoder.decode(WavEncoder.encode(pcm)), pcm);
    });

    test('decode skips unknown chunks before data', () {
      final pcm = tonePcm(const Duration(milliseconds: 20));
      final wav = WavEncoder.encode(pcm);
      final list = Uint8List.fromList([
        ...wav.sublist(0, 36),
        ...'LIST'.codeUnits,
        3,
        0,
        0,
        0,
        65,
        66,
        67,
        0, // odd-sized chunk plus pad byte
        ...wav.sublist(36),
      ]);
      expect(WavEncoder.decode(list), pcm);
    });

    Uint8List patched(void Function(ByteData d) edit) {
      final wav = WavEncoder.encode(tonePcm(const Duration(milliseconds: 20)));
      edit(ByteData.sublistView(wav));
      return wav;
    }

    test('decode rejects wrong sample rate, channels and bit depth', () {
      expect(
        () => WavEncoder.decode(
          patched((d) => d.setUint32(24, 44100, Endian.little)),
        ),
        throwsFormatException,
      );
      expect(
        () => WavEncoder.decode(
          patched((d) => d.setUint16(22, 2, Endian.little)),
        ),
        throwsFormatException,
      );
      expect(
        () => WavEncoder.decode(
          patched((d) => d.setUint16(34, 8, Endian.little)),
        ),
        throwsFormatException,
      );
    });

    test('decode rejects non-WAV and truncated input', () {
      expect(
        () => WavEncoder.decode(Uint8List.fromList(List.filled(64, 7))),
        throwsFormatException,
      );
      expect(() => WavEncoder.decode(Uint8List(10)), throwsFormatException);
      final noData = Uint8List.sublistView(
        WavEncoder.encode(Uint8List(8)),
        0,
        36,
      );
      expect(
        () => WavEncoder.decode(
          Uint8List.fromList([...noData, 0, 0, 0, 0, 0, 0, 0, 0]),
        ),
        throwsFormatException,
      );
    });

    test('decode tolerates a data size larger than the file', () {
      final wav = patched((d) => d.setUint32(40, 1 << 20, Endian.little));
      expect(WavEncoder.decode(wav).length, wav.length - 44);
    });
  });
}
