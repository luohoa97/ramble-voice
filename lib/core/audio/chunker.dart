// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

import 'pcm.dart';

/// A slice of a recording, in bytes of [Pcm] audio.
class AudioSpan {
  const AudioSpan(this.start, this.end, {this.overlap = 0, this.cutWord = false});
  final int start;
  final int end;

  /// Bytes at the start of this span that repeat the end of the previous one,
  /// so the model hears the words leading into it again.
  final int overlap;

  /// True when the previous cut fell inside speech (no pause was found): the
  /// last word written for the previous span may be a fragment.
  final bool cutWord;

  int get length => end - start;
  Duration get duration => Pcm.durationOf(length);

  @override
  bool operator ==(Object other) =>
      other is AudioSpan &&
      other.start == start &&
      other.end == end &&
      other.overlap == overlap &&
      other.cutWord == cutWord;

  @override
  int get hashCode => Object.hash(start, end, overlap, cutWord);

  @override
  String toString() =>
      'AudioSpan($start, $end${overlap == 0 ? '' : ', overlap: $overlap'}${cutWord ? ', cutWord' : ''})';
}

/// Splits long recordings into pieces no longer than an engine's per-request
/// audio limit. Each cut falls in the middle of the longest pause near the end
/// of a piece, so it lands between words. Every later piece starts a little
/// earlier ([overlap]) so the model hears the words leading into it again;
/// when no pause is found the cut falls inside speech and the piece starts
/// [overlapOnHardCut] earlier, so the split word is heard whole (the pipeline
/// removes the repeated words).
class SilenceChunker {
  const SilenceChunker({
    required this.maxChunk,
    this.searchWindow = const Duration(seconds: 10),
    this.frame = const Duration(milliseconds: 30),
    this.smoothingFrames = 5,
    this.overlap = const Duration(seconds: 1),
    this.overlapOnHardCut = const Duration(seconds: 2),
  }) : assert(searchWindow < maxChunk);

  /// Audio repeated at the start of a piece cut at a pause.
  final Duration overlap;

  /// Audio repeated at the start of a piece cut inside speech.
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
    int aligned(Duration d) => math.min(Pcm.bytesFor(d), maxBytes ~/ 4) ~/ frameBytes * frameBytes;
    final softOverlap = aligned(overlap);
    final hardOverlap = aligned(overlapOnHardCut);
    var start = 0;
    var repeat = 0;
    var cutWord = false;
    while (total - start > maxBytes) {
      final limitFrame = (start + maxBytes) ~/ frameBytes;
      // Never cut inside the repeated audio, so every piece moves forward.
      final firstFrame = math.max((start + repeat) ~/ frameBytes + 1, limitFrame - windowFrames);
      final pause = _longestPause(energy, firstFrame, limitFrame, quiet);
      final int cutFrame;
      if (pause != null) {
        cutFrame = pause;
      } else {
        // No pause: the quietest point (later on ties, so pieces stay long).
        var best = limitFrame;
        var bestScore = double.infinity;
        for (var f = firstFrame; f <= limitFrame; f++) {
          final score = _smoothed(energy, f);
          if (score <= bestScore) {
            bestScore = score;
            best = f;
          }
        }
        cutFrame = best;
      }
      final cut = math.min(cutFrame * frameBytes, start + maxBytes);
      spans.add(AudioSpan(start, cut, overlap: repeat, cutWord: cutWord));
      cutWord = pause == null;
      repeat = math.min(cutWord ? hardOverlap : softOverlap, cut - start);
      start = cut - repeat;
    }
    spans.add(AudioSpan(start, total, overlap: repeat, cutWord: cutWord));
    return spans;
  }

  /// The middle frame of the longest run of quiet frames in [from]..[to]
  /// (the later one on ties), or null when no frame there is quiet. The middle
  /// of a pause is the safest place to cut between words.
  int? _longestPause(List<double> energy, int from, int to, double quiet) {
    int? best;
    var bestLength = 0;
    var runStart = -1;
    for (var f = from; f <= to + 1; f++) {
      final isQuiet = f <= to && _smoothed(energy, f) <= quiet;
      if (isQuiet) {
        if (runStart < 0) runStart = f;
      } else if (runStart >= 0) {
        final length = f - runStart;
        if (length >= bestLength) {
          bestLength = length;
          best = runStart + length ~/ 2;
        }
        runStart = -1;
      }
    }
    return best;
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
