// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/audio/pcm.dart';
import 'package:ramble_voice/core/audio/rumble_filter.dart';

Uint8List _sine(double hz, {double amp = 8000, int seconds = 1}) {
  final n = Pcm.sampleRate * seconds;
  final out = Uint8List(n * 2);
  final d = ByteData.sublistView(out);
  for (var i = 0; i < n; i++) {
    d.setInt16(i * 2, (amp * math.sin(2 * math.pi * hz * i / Pcm.sampleRate)).round(), Endian.little);
  }
  return out;
}

double _rms(Uint8List pcm) {
  final s = Pcm.samples(pcm).skip(1600); // skip the filter's settling
  var sum = 0.0;
  for (final v in s) {
    sum += v * v;
  }
  return math.sqrt(sum / s.length);
}

void main() {
  test('engine rumble is cut', () {
    final pcm = _sine(30);
    expect(_rms(RumbleFilter.apply(pcm)), lessThan(_rms(pcm) * 0.15));
  });

  test('the voice band passes unchanged in level', () {
    for (final hz in [200.0, 1000.0, 3000.0]) {
      final pcm = _sine(hz);
      expect(_rms(RumbleFilter.apply(pcm)) / _rms(pcm), closeTo(1, 0.1), reason: '$hz Hz');
    }
  });

  test('empty input is returned as is', () {
    expect(RumbleFilter.apply(Uint8List(0)), isEmpty);
  });
}
