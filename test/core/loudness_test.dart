// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/audio/auto_gain.dart';
import 'package:ramble_voice/core/audio/pcm.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/cleanup/cleanup_prompt.dart';
import 'package:ramble_voice/core/style/style_profile.dart';

Uint8List _voice(double amplitude) {
  final n = Pcm.sampleRate;
  final out = Uint8List(n * 2);
  final d = ByteData.sublistView(out);
  for (var i = 0; i < n; i++) {
    d.setInt16(i * 2, (amplitude * math.sin(2 * math.pi * 220 * i / Pcm.sampleRate)).round(), Endian.little);
  }
  return out;
}

void main() {
  test('whispering, ordinary and shouting are told apart before levelling', () {
    expect(AutoGain.describeLoudness(_voice(150)), contains('whisper'));
    expect(AutoGain.describeLoudness(_voice(3000)), isNull);
    expect(AutoGain.describeLoudness(_voice(32767)), contains('shouting'));
  });

  test('the measured loudness reaches the model as a hint, and the emotion rule is always there', () {
    final r = CleanupRequest(pcm: Uint8List(0), style: const StyleProfile(), loudness: 'very loud: raised voice or shouting');
    expect(CleanupPrompt.userTextFor(r), contains('<voice>Measured before volume levelling, the speaker was very loud'));
    expect(CleanupPrompt.systemFor(r), contains('emotion and energy'));
    final plain = CleanupRequest(pcm: Uint8List(0), style: const StyleProfile());
    expect(CleanupPrompt.userTextFor(plain), isNot(contains('<voice>')));
  });
}
