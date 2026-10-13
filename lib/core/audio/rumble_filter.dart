// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

import 'pcm.dart';

/// Removes low rumble (bus and car engines, road vibration, handling noise)
/// below the voice before the recording is sent to the model. A
/// second-order Butterworth high-pass at [cutoffHz]: speech starts around
/// 100 Hz and its intelligibility lives far above that, so nothing spoken is
/// lost, but the rumble no longer dominates the level that [AutoGain]
/// measures or masks the voice.
abstract final class RumbleFilter {
  static const double cutoffHz = 85;

  static Uint8List apply(Uint8List pcm) {
    final input = Pcm.samples(pcm);
    if (input.isEmpty) return pcm;
    final w = 2 * math.pi * cutoffHz / Pcm.sampleRate;
    final cosW = math.cos(w);
    final alpha = math.sin(w) / (2 * math.sqrt1_2);
    final a0 = 1 + alpha;
    final b0 = (1 + cosW) / 2 / a0;
    final b1 = -(1 + cosW) / a0;
    final b2 = b0;
    final a1 = -2 * cosW / a0;
    final a2 = (1 - alpha) / a0;

    final out = Uint8List(input.length * Pcm.bytesPerSample);
    final data = ByteData.sublistView(out);
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0;
    for (var i = 0; i < input.length; i++) {
      final x = input[i].toDouble();
      final y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
      x2 = x1;
      x1 = x;
      y2 = y1;
      y1 = y;
      data.setInt16(i * 2, y.round().clamp(-32768, 32767), Endian.little);
    }
    return out;
  }
}
