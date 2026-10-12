// SPDX-License-Identifier: GPL-3.0-or-later
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/audio/auto_gain.dart';
import 'package:ramble_voice/core/audio/pcm.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_client.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_engine.dart';
import 'package:ramble_voice/core/style/style_profile.dart';

/// Words from other languages come out in their own script, e.g. a spoken
/// "sayonara" in English speech becomes さようなら.
/// GEMINI_API_KEY=... RAMBLE_WAV=path RAMBLE_EXPECT=regex [RAMBLE_MODELS=a,b] [RAMBLE_GAIN=0] [RAMBLE_EDIT=text to edit]
/// tool/fl flutter test --run-skipped -t live test/live/script_probe_test.dart
void main() {
  final env = Platform.environment;
  final key = env['GEMINI_API_KEY'];
  final wavPath = env['RAMBLE_WAV'];
  final expected = env['RAMBLE_EXPECT'];
  final models = (env['RAMBLE_MODELS'] ?? 'gemini-3.5-flash').split(',');
  for (final model in models) {
    test('native script $model', () async {
      final engine = GeminiEngine(apiKey: () async => key, client: GeminiClient(), preferredModel: model);
      final out = await engine.process(CleanupRequest(
        pcm: env['RAMBLE_GAIN'] == '0'
            ? WavEncoder.decode(File(wavPath!).readAsBytesSync())
            : AutoGain.normalize(WavEncoder.decode(File(wavPath!).readAsBytesSync())),
        style: const StyleProfile(languages: ['en', 'zh', 'ja']),
        mode: env['RAMBLE_EDIT'] == null ? CleanupMode.clean : CleanupMode.edit,
        sourceText: env['RAMBLE_EDIT'],
      ));
      // ignore: avoid_print
      print('PROBE $model: $out');
      expect(RegExp(expected!).hasMatch(out), isTrue, reason: out);
    },
        skip: key == null || wavPath == null || expected == null
            ? 'needs GEMINI_API_KEY, RAMBLE_WAV and RAMBLE_EXPECT'
            : false,
        timeout: const Timeout(Duration(minutes: 3)));
  }
}
