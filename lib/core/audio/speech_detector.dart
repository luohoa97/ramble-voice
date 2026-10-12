// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'pcm.dart';

/// What [SpeechDetector.analyze] found.
class SpeechAnalysis {
  const SpeechAnalysis({
    required this.frames,
    required this.speechFrames,
    required this.longestRun,
    required this.noiseFloorPower,
  });

  final int frames;

  /// Frames that look like speech.
  final int speechFrames;

  /// Longest run of consecutive speech-like frames.
  final int longestRun;

  /// Mean-square level (0..1 of full scale squared) of the quiet-frame floor.
  final double noiseFloorPower;

  Duration get speechDuration => SpeechDetector.frameDuration * speechFrames;
  Duration get longestRunDuration => SpeechDetector.frameDuration * longestRun;

  /// Enough speech-like audio, with at least one syllable-length stretch.
  bool get hasSpeech =>
      speechDuration >= SpeechDetector.minTotalSpeech && longestRunDuration >= SpeechDetector.minRun;
}

/// A cheap gate that keeps steady non-speech noise (air conditioning, fans,
/// hum, a quiet room) from being sent to the model, which would "transcribe"
/// it into invented words.
///
/// Per 30 ms frame it measures power and zero-crossing rate. The noise floor is
/// the 20th-percentile frame power, so the quietest fifth of the recording
/// defines "background". A frame is speech-like when it is clearly above that
/// floor, above an absolute minimum, and has a speech-like zero-crossing rate.
/// Steady noise is the same power in every frame, so no frame stands out;
/// speech rises and falls with syllables, so it does.
///
/// The one exception is [loudPower]: a frame that loud is accepted without
/// standing out, because a person speaking continuously (or a test tone) has
/// no quiet frames to define a floor. A very loud steady noise therefore still
/// passes the gate; the model then decides, as before.
abstract final class SpeechDetector {
  static const Duration frameDuration = Duration(milliseconds: 30);

  /// Samples per frame at 16 kHz.
  static const int frameSamples = Pcm.sampleRate * 30 ~/ 1000;

  /// Fraction of frames, from the quiet end, taken as the noise floor.
  static const double floorPercentile = 0.20;

  /// A frame must exceed the floor power by this factor (about +8 dB).
  static const double floorRatio = 6.0;

  /// Frames below -50 dBFS RMS (power 1e-5) are never speech.
  static const double minPower = 1e-5;

  /// Frames at or above -30 dBFS RMS (power 1e-3) count without needing to
  /// stand out from the floor.
  static const double loudPower = 1e-3;

  /// Zero crossings per sample for speech-like frames. Below the minimum is
  /// rumble or hum (a 60 Hz hum crosses 0.0075 per sample); voiced speech sits
  /// around 0.02-0.15 and fricatives up to about 0.5.
  static const double minZeroCrossingRate = 0.015;
  static const double maxZeroCrossingRate = 0.6;

  /// Total speech-like audio required.
  static const Duration minTotalSpeech = Duration(milliseconds: 300);

  /// At least one unbroken speech-like stretch this long (about a syllable).
  static const Duration minRun = Duration(milliseconds: 120);

  static SpeechAnalysis analyze(Uint8List pcm) {
    final samples = Pcm.samples(pcm);
    final frames = samples.length ~/ frameSamples;
    if (frames == 0) {
      return const SpeechAnalysis(frames: 0, speechFrames: 0, longestRun: 0, noiseFloorPower: 0);
    }
    final power = Float64List(frames);
    final zcr = Float64List(frames);
    for (var f = 0; f < frames; f++) {
      final start = f * frameSamples;
      var sum = 0.0;
      var crossings = 0;
      var prev = samples[start];
      for (var i = 0; i < frameSamples; i++) {
        final v = samples[start + i];
        sum += v * v;
        if (i > 0 && (v >= 0) != (prev >= 0)) crossings++;
        prev = v;
      }
      power[f] = sum / frameSamples / (32768.0 * 32768.0);
      zcr[f] = crossings / frameSamples;
    }

    final sorted = power.toList()..sort();
    final floor = sorted[((frames - 1) * floorPercentile).floor()];

    var speech = 0;
    var run = 0;
    var longest = 0;
    for (var f = 0; f < frames; f++) {
      final p = power[f];
      final speechLike = p >= minPower &&
          zcr[f] >= minZeroCrossingRate &&
          zcr[f] <= maxZeroCrossingRate &&
          (p >= loudPower || p > floor * floorRatio);
      if (speechLike) {
        speech++;
        run++;
        if (run > longest) longest = run;
      } else {
        run = 0;
      }
    }
    return SpeechAnalysis(frames: frames, speechFrames: speech, longestRun: longest, noiseFloorPower: floor);
  }

  static bool hasSpeech(Uint8List pcm) => analyze(pcm).hasSpeech;
}
