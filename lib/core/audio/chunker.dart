// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

import 'pcm.dart';

/// A slice of a recording, in bytes of [Pcm] audio.
class AudioSpan {
  const AudioSpan(this.start, this.end, {this.overlap = 0});
  final int start;
  final int end;

  /// Bytes at the start of this span that repeat the end of the previous one.
  /// Set when the previous cut fell inside speech (no pause was found), so a
  /// word split by the cut is heard whole again.
  final int overlap;

  int get length => end - start;
  Duration get duration => Pcm.durationOf(length);

  @override
  bool operator ==(Object other) =>
      other is AudioSpan && other.start == start && other.end == end && other.overlap == overlap;

  @override
  int get hashCode => Object.hash(start, end, overlap);

  @override
  String toString() => 'AudioSpan($start, $end${overlap == 0 ? '' : ', overlap: $overlap'})';
}

/// Splits long recordings into pieces no longer than an engine's per-request
/// audio limit, cutting at the quietest point near the end of each piece so
/// words are not split. When no pause is found the cut falls inside speech:
/// the next chunk then starts [overlapOnHardCut] earlier, so the split word is
/// heard whole again (the pipeline removes the repeated words).
class SilenceChunker {
  const SilenceChunker({
    required this.maxChunk,
    this.searchWindow = const Duration(seconds: 6),
    this.frame = const Duration(milliseconds: 30),
    this.smoothingFrames = 5,
    this.overlapOnHardCut = const Duration(seconds: 2),
  }) : assert(searchWindow < maxChunk);

  final Duration overlapOnHardCut;

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
    // A pause is well below the recording's typical level; a cut above that
    // fell inside speech. (In steady noise this errs towards overlapping,
    // which only costs a few repeated seconds.)
    final sorted = [...energy]..sort();
    final quiet = sorted.isEmpty ? 0.0 : sorted[sorted.length ~/ 2] * 0.25 + 1;
    final overlapBytes = math.min(Pcm.bytesFor(overlapOnHardCut), maxBytes ~/ 4) ~/ frameBytes * frameBytes;
    var start = 0;
    var overlap = 0;
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
      spans.add(AudioSpan(start, cut, overlap: overlap));
      final hard = bestScore > quiet;
      overlap = hard ? math.min(overlapBytes, cut - start) : 0;
      start = cut - overlap;
    }
    spans.add(AudioSpan(start, total, overlap: overlap));
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
  /// [next] without the words at its start that repeat the end of [previous]
  /// (overlapping chunks hear the same words twice). Compares words without
  /// case or punctuation; up to [maxWords].
  static String dropRepeatedHead(String previous, String next, {int maxWords = 12}) {
    final prev = previous.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final nextWords = RegExp(r'\S+').allMatches(next).toList();
    String norm(String w) => w.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    for (var k = math.min(maxWords, math.min(prev.length, nextWords.length)); k > 0; k--) {
      var same = true;
      for (var i = 0; i < k; i++) {
        final a = norm(prev[prev.length - k + i]);
        if (a.isEmpty || a != norm(nextWords[i].group(0)!)) {
          same = false;
          break;
        }
      }
      if (same) return next.substring(nextWords[k - 1].end).trimLeft();
    }
    return next;
  }

  /// [text] without its last word (a word the chunk cut may have split).
  static String dropLastWord(String text) {
    final t = text.trimRight();
    final i = t.lastIndexOf(RegExp(r'\s'));
    return i < 0 ? '' : t.substring(0, i).trimRight();
  }

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
