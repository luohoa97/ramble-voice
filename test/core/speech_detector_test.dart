// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/audio/pcm.dart';
import 'package:ramble_voice/core/audio/speech_detector.dart';

import '../fakes/pcm_fixtures.dart';

const _sr = Pcm.sampleRate;

/// Deterministic noise in -1..1 (LCG), so tests never flake.
class _Noise {
  _Noise([this._s = 12345]);
  int _s;
  double next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s / 0x3fffffff - 1;
  }
}

Uint8List _render(Duration d, double Function(int i) sample) {
  final n = Pcm.bytesFor(d) ~/ 2;
  final out = Uint8List(n * 2);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < n; i++) {
    bd.setInt16(i * 2, (sample(i).clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return out;
}

double _dbToAmp(double db) => math.pow(10, db / 20).toDouble();

/// An air conditioner: 60 and 120 Hz hum plus broadband rumble, at about [db] dBFS RMS.
Uint8List _ac(Duration d, {double db = -40, int seed = 1}) {
  final noise = _Noise(seed);
  final amp = _dbToAmp(db);
  return _render(d, (i) {
    final t = i / _sr;
    final hum = 0.6 * math.sin(2 * math.pi * 60 * t) + 0.3 * math.sin(2 * math.pi * 120 * t);
    return amp * (0.8 * hum + 0.9 * noise.next());
  });
}

/// Pink-ish noise: a one-pole low-passed white noise.
Uint8List _pink(Duration d, {double db = -38}) {
  final noise = _Noise(99);
  var lp = 0.0;
  final amp = _dbToAmp(db) * 3;
  return _render(d, (i) {
    lp = 0.9 * lp + 0.1 * noise.next();
    return amp * lp;
  });
}

/// Syllable-like bursts: a voiced buzz with formant-ish harmonics, amplitude
/// shaped 0 -> 1 -> 0 over [burst], followed by [gap] of nothing.
Uint8List _syllables(int count, {Duration burst = const Duration(milliseconds: 180), Duration gap = const Duration(milliseconds: 120), double db = -24}) {
  final amp = _dbToAmp(db) * 1.6;
  final parts = <Uint8List>[];
  for (var k = 0; k < count; k++) {
    final f0 = 130.0 + 15 * (k % 3);
    parts.add(_render(burst, (i) {
      final t = i / _sr;
      final env = math.sin(math.pi * i / (burst.inMicroseconds * _sr / 1e6));
      var v = 0.0;
      for (var h = 1; h <= 8; h++) {
        v += math.sin(2 * math.pi * f0 * h * t) / h;
      }
      return amp * env * v;
    }));
    parts.add(Uint8List(Pcm.bytesFor(gap)));
  }
  return concatBytes(parts);
}

Uint8List _mix(Uint8List a, Uint8List b) {
  final n = math.min(a.length, b.length) ~/ 2;
  final out = Uint8List(n * 2);
  final bd = ByteData.sublistView(out);
  final sa = Pcm.samples(a), sb = Pcm.samples(b);
  for (var i = 0; i < n; i++) {
    bd.setInt16(i * 2, (sa[i] + sb[i]).clamp(-32768, 32767), Endian.little);
  }
  return out;
}

void main() {
  const long = Duration(seconds: 3);

  group('no speech', () {
    test('digital silence', () {
      expect(SpeechDetector.hasSpeech(silencePcm(long)), isFalse);
    });

    test('empty and sub-frame input', () {
      expect(SpeechDetector.hasSpeech(Uint8List(0)), isFalse);
      expect(SpeechDetector.hasSpeech(Uint8List(100)), isFalse);
    });

    test('air-conditioner hum with broadband noise', () {
      for (final db in [-48.0, -42.0, -36.0, -32.0]) {
        final a = SpeechDetector.analyze(_ac(long, db: db));
        expect(a.hasSpeech, isFalse, reason: 'ac at $db dB: ${a.speechFrames}/${a.frames} speech frames');
      }
    });

    test('pink noise', () {
      expect(SpeechDetector.hasSpeech(_pink(long)), isFalse);
    });

    test('white noise', () {
      final n = _Noise(7);
      expect(SpeechDetector.hasSpeech(_render(long, (_) => 0.02 * n.next())), isFalse);
    });

    test('pure low hum below the speech zero-crossing range, even when loud-ish', () {
      final hum = _render(long, (i) => 0.02 * math.sin(2 * math.pi * 60 * i / _sr));
      expect(SpeechDetector.hasSpeech(hum), isFalse);
    });

    test('a single click is too short', () {
      final bed = _ac(long, db: -45);
      final click = _render(const Duration(milliseconds: 40), (i) => 0.3 * math.sin(2 * math.pi * 800 * i / _sr));
      final mixed = Uint8List.fromList(bed)..setRange(Pcm.bytesFor(const Duration(seconds: 1)), Pcm.bytesFor(const Duration(seconds: 1)) + click.length, click);
      expect(SpeechDetector.hasSpeech(mixed), isFalse);
    });
  });

  group('speech', () {
    test('syllable bursts in silence', () {
      expect(SpeechDetector.hasSpeech(_syllables(6)), isTrue);
    });

    test('syllable bursts over air-conditioner noise', () {
      final speech = _syllables(8);
      final bed = _ac(Pcm.durationOf(speech.length), db: -40);
      final a = SpeechDetector.analyze(_mix(speech, bed));
      expect(a.hasSpeech, isTrue, reason: '${a.speechFrames}/${a.frames}, run ${a.longestRun}');
    });

    test('syllable bursts over pink noise', () {
      final speech = _syllables(8);
      final bed = _pink(Pcm.durationOf(speech.length), db: -42);
      expect(SpeechDetector.hasSpeech(_mix(speech, bed)), isTrue);
    });

    test('amplitude-modulated noise like fricatives over a quiet bed', () {
      final n = _Noise(3);
      final burst = _render(const Duration(milliseconds: 600), (i) {
        final env = math.sin(math.pi * i / (0.6 * _sr));
        return 0.08 * env * n.next();
      });
      final bed = _ac(const Duration(seconds: 2), db: -50);
      final out = Uint8List.fromList(bed)..setRange(Pcm.bytesFor(const Duration(milliseconds: 500)), Pcm.bytesFor(const Duration(milliseconds: 500)) + burst.length, burst);
      expect(SpeechDetector.hasSpeech(out), isTrue);
    });

    test('the controller test fixtures (steady tones) count as speech', () {
      expect(SpeechDetector.hasSpeech(tonePcm(const Duration(seconds: 1))), isTrue);
      expect(SpeechDetector.hasSpeech(tonePcm(const Duration(seconds: 1), amplitude: 1.0)), isTrue);
      expect(SpeechDetector.hasSpeech(tonePcm(const Duration(milliseconds: 700))), isTrue);
    });
  });

  test('analysis reports durations', () {
    final a = SpeechDetector.analyze(tonePcm(const Duration(seconds: 1)));
    expect(a.frames, 33);
    expect(a.speechDuration, SpeechDetector.frameDuration * a.speechFrames);
    expect(a.longestRunDuration, greaterThanOrEqualTo(SpeechDetector.minRun));
  });
}
