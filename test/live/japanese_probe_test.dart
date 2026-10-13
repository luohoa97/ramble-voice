// SPDX-License-Identifier: GPL-3.0-or-later
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/audio/pcm.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_client.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_engine.dart';
import 'package:ramble_voice/core/style/style_profile.dart';

/// Japanese speech must come out in kana/kanji, not romaji.
/// GEMINI_API_KEY=... RAMBLE_JA_WAV=path tool/fl flutter test --run-skipped -t live test/live/japanese_probe_test.dart
void main() {
  final key = Platform.environment['GEMINI_API_KEY'];
  final wavPath = Platform.environment['RAMBLE_JA_WAV'];
  for (final model in ['gemini-3.5-flash', 'gemini-3.5-flash-lite']) {
    test('japanese script $model', () async {
      final engine = GeminiEngine(apiKey: () async => key, client: GeminiClient(), preferredModel: model);
      final out = await engine.process(CleanupRequest(
        pcm: WavEncoder.decode(File(wavPath!).readAsBytesSync()),
        style: const StyleProfile(languages: ['en', 'zh', 'ja']),
      ));
      // ignore: avoid_print
      print('PROBE $model: $out');
      expect(RegExp(r'[぀-ヿ一-鿿]').hasMatch(out), isTrue, reason: out);
      expect(RegExp(r'[a-zA-Z]{4,}').hasMatch(out), isFalse, reason: 'romaji: $out');
    }, skip: key == null || wavPath == null ? 'needs GEMINI_API_KEY and RAMBLE_JA_WAV' : false, timeout: const Timeout(Duration(minutes: 3)));
  }
}
