// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

import 'pcm.dart';

/// Raises quiet recordings to a normal speaking level before they are sent to
/// a model. Speech said softly, or with the phone held away, otherwise reaches
/// the model near the noise floor and gets misheard or dropped.
///
/// The level is measured on the loud end of the recording (the 90th-percentile
/// 30 ms frame), so pauses do not count. Gain is only ever raised, never
/// lowered, and is capped at [maxGainDb] so a silent room is not turned into
/// loud hiss. Peaks that would clip are softly limited.
abstract final class AutoGain {
  /// Target RMS for the loud frames, in dBFS.
  static const double targetDb = -18;

  /// The most gain applied.
  static const double maxGainDb = 24;

  /// Below this much gain the audio is returned unchanged.
  static const double minGainDb = 1;

  static const int _frameSamples = Pcm.sampleRate * 30 ~/ 1000;

  /// The gain in dB that [normalize] would apply to [pcm].
  static double gainDbFor(Uint8List pcm) {
    final s = Pcm.samples(pcm);
    final frames = s.length ~/ _frameSamples;
    if (frames == 0) return 0;
    final rms = <double>[];
    for (var f = 0; f < frames; f++) {
      var sum = 0.0;
      for (var i = f * _frameSamples, end = i + _frameSamples; i < end; i++) {
        sum += s[i] * s[i];
      }
      rms.add(math.sqrt(sum / _frameSamples) / 32768.0);
    }
    rms.sort();
    final loud = rms[((frames - 1) * 0.9).floor()];
    if (loud <= 0) return 0;
    final db = 20 * math.log(loud) / math.ln10;
    return (targetDb - db).clamp(0.0, maxGainDb);
  }

  /// [pcm] with quiet speech raised to a normal level; the input itself when
  /// it is already loud enough.
  static Uint8List normalize(Uint8List pcm) {
    final gainDb = gainDbFor(pcm);
    if (gainDb < minGainDb) return pcm;
    final gain = math.pow(10, gainDb / 20).toDouble();
    final s = Pcm.samples(pcm);
    final out = Int16List(s.length);
    const knee = 0.8 * 32767;
    for (var i = 0; i < s.length; i++) {
      final v = s[i] * gain;
      final a = v.abs();
      // Soft limiter above the knee: approaches full scale, never clips.
      final limited = a <= knee ? a : knee + (32767 - knee) * _tanh((a - knee) / (32767 - knee));
      out[i] = (v < 0 ? -limited : limited).round();
    }
    final bytes = ByteData(out.length * Pcm.bytesPerSample);
    for (var i = 0; i < out.length; i++) {
      bytes.setInt16(i * Pcm.bytesPerSample, out[i], Endian.little);
    }
    return bytes.buffer.asUint8List();
  }

  static double _tanh(double x) {
    final e = math.exp(2 * x);
    return (e - 1) / (e + 1);
  }
}
