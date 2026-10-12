// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

import 'pcm.dart';

/// A slice of a recording, in bytes of [Pcm] audio.
class AudioSpan {
  const AudioSpan(this.start, this.end);
  final int start;
  final int end;

  int get length => end - start;
  Duration get duration => Pcm.durationOf(length);

  @override
  bool operator ==(Object other) => other is AudioSpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'AudioSpan($start, $end)';
}

/// Splits long recordings into pieces no longer than an engine's per-request
/// audio limit, cutting at the quietest point near the end of each piece so
/// words are not split. Chunks never overlap, so stitched text has no
/// duplicated words.
class SilenceChunker {
  const SilenceChunker({
    required this.maxChunk,
    this.searchWindow = const Duration(seconds: 6),
    this.frame = const Duration(milliseconds: 30),
    this.smoothingFrames = 5,
  }) : assert(searchWindow < maxChunk);

  final Duration maxChunk;

  /// How far back from [maxChunk] to look for a pause.
  final Duration searchWindow;
  final Duration frame;
  final int smoothingFrames;

  List<AudioSpan> plan(Uint8List pcm) {
    final total = pcm.lengthInBytes - pcm.lengthInBytes % Pcm.bytesPerSample;
    final maxBytes = Pcm.bytesFor(maxChunk);
    if (total <= maxBytes) return total == 0 ? const [] : [AudioSpan(0, total)];

    final frameBytes = Pcm.bytesFor(frame);
    final energy = _frameEnergy(pcm, total, frameBytes);
    final windowFrames = Pcm.bytesFor(searchWindow) ~/ frameBytes;

    final spans = <AudioSpan>[];
    var start = 0;
    while (total - start > maxBytes) {
      final limitFrame = (start + maxBytes) ~/ frameBytes;
      final firstFrame = math.max(start ~/ frameBytes + 1, limitFrame - windowFrames);
      var best = limitFrame;
      var bestScore = double.infinity;
      for (var f = firstFrame; f <= limitFrame; f++) {
        final score = _smoothed(energy, f);
        // Prefer later cuts on ties so chunks stay close to the limit.
        if (score <= bestScore) {
          bestScore = score;
          best = f;
        }
      }
      final cut = math.min(best * frameBytes, start + maxBytes);
      spans.add(AudioSpan(start, cut));
      start = cut;
    }
    spans.add(AudioSpan(start, total));
    return spans;
  }

  List<double> _frameEnergy(Uint8List pcm, int total, int frameBytes) {
    final s = Pcm.samples(Uint8List.sublistView(pcm, 0, total));
    final perFrame = frameBytes ~/ Pcm.bytesPerSample;
    final count = (s.length / perFrame).ceil();
    return List<double>.generate(count, (f) {
      final from = f * perFrame;
      final to = math.min(from + perFrame, s.length);
      var sum = 0.0;
      for (var i = from; i < to; i++) {
        sum += s[i] * s[i];
      }
      return to > from ? sum / (to - from) : 0;
    });
  }

  double _smoothed(List<double> e, int center) {
    final half = smoothingFrames ~/ 2;
    var sum = 0.0;
    var n = 0;
    for (var i = center - half; i <= center + half; i++) {
      if (i >= 0 && i < e.length) {
        sum += e[i];
        n++;
      }
    }
    return n == 0 ? double.infinity : sum / n;
  }
}

/// Joins per-chunk cleaned text into one result.
abstract final class TextStitcher {
  static String join(Iterable<String> parts) {
    final cleaned = parts.map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    if (cleaned.isEmpty) return '';
    final buffer = StringBuffer(cleaned.first);
    for (final part in cleaned.skip(1)) {
      final prev = buffer.toString();
      // A model may start a later chunk mid-paragraph; keep paragraph breaks
      // it produced, otherwise join with a single space.
      final separator = prev.endsWith('\n') || part.startsWith('\n') ? '' : ' ';
      buffer
        ..write(separator)
        ..write(part);
    }
    return buffer.toString().replaceAll(RegExp(r'[ \t]+'), ' ').trim();
  }
}
