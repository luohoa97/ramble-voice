// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/audio/chunker.dart';
import 'package:ramble_voice/core/audio/pcm.dart';

import '../fakes/pcm_fixtures.dart';

const _s = Duration(seconds: 1);

/// Speech-like audio: [talk] seconds of tone then a [gap] of silence, repeated.
Uint8List _speech({required int seconds, int talk = 4, double gapSeconds = 0.8}) {
  final parts = <Uint8List>[];
  var total = 0.0;
  while (total < seconds) {
    parts.add(tonePcm(Duration(seconds: talk)));
    parts.add(silencePcm(Duration(milliseconds: (gapSeconds * 1000).round())));
    total += talk + gapSeconds;
  }
  final all = concatBytes(parts);
  return Uint8List.sublistView(all, 0, Pcm.bytesFor(Duration(seconds: seconds)));
}

bool _isQuiet(Uint8List pcm, int at, {int around = 480}) {
  final s = Pcm.samples(Uint8List.sublistView(pcm, at - around, at + around));
  return s.every((v) => v.abs() < 50);
}

void main() {
  group('SilenceChunker.plan', () {
    final chunker = SilenceChunker(maxChunk: Duration(seconds: 28));

    test('empty input has no spans', () {
      expect(chunker.plan(Uint8List(0)), isEmpty);
      expect(chunker.plan(Uint8List(1)), isEmpty);
    });

    test('short audio is a single span', () {
      final pcm = tonePcm(const Duration(seconds: 10));
      expect(chunker.plan(pcm), [AudioSpan(0, pcm.length)]);
    });

    test('exactly maxChunk is a single span', () {
      final pcm = tonePcm(const Duration(seconds: 28));
      expect(chunker.plan(pcm), hasLength(1));
    });

    test('odd byte length drops the dangling byte', () {
      final pcm = Uint8List(Pcm.bytesFor(_s) + 1);
      expect(chunker.plan(pcm), [AudioSpan(0, Pcm.bytesFor(_s))]);
    });

    test('long audio: contiguous, covering, never above maxChunk', () {
      final pcm = _speech(seconds: 150);
      final spans = chunker.plan(pcm);
      expect(spans.length, greaterThan(4));
      expect(spans.first.start, 0);
      expect(spans.last.end, pcm.length - pcm.length % 2);
      for (var i = 0; i < spans.length; i++) {
        expect(spans[i].duration, lessThanOrEqualTo(chunker.maxChunk), reason: 'span $i');
        expect(spans[i].length, greaterThan(0));
        if (i > 0) expect(spans[i].start, spans[i - 1].end, reason: 'no gap or overlap at $i');
      }
    });

    test('cuts land inside silence gaps', () {
      final pcm = _speech(seconds: 150);
      final spans = chunker.plan(pcm);
      for (final span in spans.take(spans.length - 1)) {
        expect(_isQuiet(pcm, span.end), isTrue, reason: 'cut at ${Pcm.durationOf(span.end)} is mid-speech');
      }
    });

    test('continuous speech still respects maxChunk', () {
      final pcm = tonePcm(const Duration(seconds: 100));
      final spans = chunker.plan(pcm);
      expect(spans.length, greaterThanOrEqualTo(4));
      for (final s in spans) {
        expect(s.duration, lessThanOrEqualTo(chunker.maxChunk));
      }
      expect(spans.fold<int>(0, (a, s) => a + s.length), pcm.length);
    });

    test('works with a tiny limit', () {
      final small = SilenceChunker(maxChunk: Duration(seconds: 4), searchWindow: Duration(seconds: 1));
      final pcm = _speech(seconds: 30, talk: 2, gapSeconds: 0.5);
      final spans = small.plan(pcm);
      expect(spans.fold<int>(0, (a, s) => a + s.length), pcm.length);
      for (final s in spans) {
        expect(s.duration, lessThanOrEqualTo(small.maxChunk));
      }
    });

    test('AudioSpan equality and duration', () {
      expect(const AudioSpan(0, 32000), const AudioSpan(0, 32000));
      expect(const AudioSpan(0, 32000).hashCode, const AudioSpan(0, 32000).hashCode);
      expect(const AudioSpan(32000, 96000).duration, const Duration(seconds: 2));
    });
  });

  group('TextStitcher.join', () {
    test('joins with single spaces', () {
      expect(TextStitcher.join(['Hello there.', 'How are you?']), 'Hello there. How are you?');
    });

    test('trims, drops empty parts, handles none', () {
      expect(TextStitcher.join(['  a  ', '', '   ', 'b\n']), 'a b');
      expect(TextStitcher.join(const []), '');
      expect(TextStitcher.join(['', ' ']), '');
    });

    test('keeps paragraph breaks inside a part', () {
      expect(TextStitcher.join(['one\n\ntwo', 'three']), 'one\n\ntwo three');
    });

    test('edge newlines are trimmed before joining', () {
      expect(TextStitcher.join(['- a\n', '\nb']), '- a b');
    });

    test('collapses runs of spaces', () {
      expect(TextStitcher.join(['a   b', 'c']), 'a b c');
    });
  });
}
