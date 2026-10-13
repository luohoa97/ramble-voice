// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/audio/auto_gain.dart';
import 'package:ramble_voice/core/audio/pcm.dart';

Uint8List _tone(double amplitude, {int ms = 1000}) {
  final n = Pcm.sampleRate * ms ~/ 1000;
  final b = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    b.setInt16(i * 2, (amplitude * 32767 * math.sin(2 * math.pi * 220 * i / Pcm.sampleRate)).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

int _peak(Uint8List pcm) => Pcm.samples(pcm).fold(0, (m, v) => math.max(m, v.abs()));

void main() {
  test('quiet speech is raised', () {
    final quiet = _tone(0.01); // about -43 dBFS RMS
    final out = AutoGain.normalize(quiet);
    expect(AutoGain.gainDbFor(quiet), AutoGain.maxGainDb);
    expect(_peak(out), greaterThan(_peak(quiet) * 10));
  });

  test('normal speech is left alone', () {
    final loud = _tone(0.3);
    expect(identical(AutoGain.normalize(loud), loud), isTrue);
  });

  test('never clips', () {
    final mixed = Uint8List.fromList([..._tone(0.02), ..._tone(0.9, ms: 30)]);
    final out = AutoGain.normalize(mixed);
    expect(_peak(out), lessThanOrEqualTo(32767));
    expect(out.length, mixed.length);
  });

  test('silence and empty input pass through', () {
    expect(AutoGain.normalize(Uint8List(0)), isEmpty);
    final silent = Uint8List(3200);
    expect(AutoGain.normalize(silent), same(silent));
  });
}
