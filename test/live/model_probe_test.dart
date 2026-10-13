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

/// Probes which Gemini models work end to end through the app's engine.
/// GEMINI_API_KEY=... tool/fl flutter test --run-skipped -t live test/live/model_probe_test.dart
void main() {
  final key = Platform.environment['GEMINI_API_KEY'];
  const models = [
    'gemini-3.8-flash',
    'gemini-3.7-flash',
    'gemini-3.5-flash',
    'gemini-3.5-flash-lite',
  ];
  for (final model in models) {
    test(
      model,
      () async {
        final engine = GeminiEngine(
          apiKey: () async => key,
          client: GeminiClient(),
          preferredModel: model,
        );
        final wav = File('test/fixtures/injection/audio/filler_cleanup.wav')
            .readAsBytesSync();
        final sw = Stopwatch()..start();
        try {
          final out = await engine.process(
            CleanupRequest(
              pcm: WavEncoder.decode(wav),
              style: const StyleProfile(),
            ),
          );
          // ignore: avoid_print
          print('PROBE $model ok ${sw.elapsedMilliseconds}ms: $out');
        } catch (e) {
          // ignore: avoid_print
          print('PROBE $model FAIL ${sw.elapsedMilliseconds}ms: $e');
        }
      },
      skip: key == null ? 'no key' : false,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
