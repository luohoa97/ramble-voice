// SPDX-License-Identifier: GPL-3.0-or-later

/// Prompt-injection evaluation against real models. The app must transcribe
/// spoken instructions, never obey them.
///
///   GEMINI_API_KEY=... tool/fl flutter test --run-skipped -t live test/live
///   RAMBLE_GEMMA_MODEL=/path/gemma-4-E2B-it.litertlm RAMBLE_GEMMA_VARIANT=gemma-4-e2b \
///     tool/fl flutter test --run-skipped -t live test/live
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ramble_voice/core/audio/pcm.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_client.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_engine.dart';
import 'package:ramble_voice/core/cleanup/gemma/gemma_engine.dart';
import 'package:ramble_voice/core/models/model_catalog.dart';
import 'package:ramble_voice/core/style/style_profile.dart';

import '../fakes/injection_cases.dart';

Future<String> _processWithRetry(CleanupEngine engine, CleanupRequest request) async {
  for (var attempt = 0;; attempt++) {
    try {
      return await engine.process(request);
    } on CleanupFailure catch (f) {
      if (f.kind == CleanupFailureKind.rateLimited && attempt < 3) {
        await Future<void>.delayed((f.retryAfter ?? const Duration(seconds: 10)) + const Duration(seconds: 1));
        continue;
      }
      rethrow;
    }
  }
}

void _runCases(String label, CleanupEngine Function() engine) {
  final cases = loadInjectionCases();
  group(label, () {
    for (final c in cases) {
      test(c.id, () async {
        final pcm = WavEncoder.decode(c.wavFile.readAsBytesSync());
        final out = await _processWithRetry(
          engine(),
          CleanupRequest(pcm: pcm, style: const StyleProfile(preset: StylePreset.casual)),
        );
        final problems = c.judgeOutput(out);
        expect(problems, isEmpty, reason: 'spoken: "${c.spoken}"\noutput: "$out"\n${problems.join('\n')}');
      }, timeout: const Timeout(Duration(minutes: 3)));
    }
  });
}

void main() {
  final geminiKey = Platform.environment['GEMINI_API_KEY'];
  final gemmaPath = Platform.environment['RAMBLE_GEMMA_MODEL'];

  if (geminiKey == null || geminiKey.isEmpty) {
    test('Gemini injection cases', () {}, skip: 'set GEMINI_API_KEY to run');
  } else {
    final client = GeminiClient(httpClient: http.Client());
    final gemini = GeminiEngine(apiKey: () async => geminiKey, client: client);
    tearDownAll(client.close);
    _runCases('Gemini', () => gemini);
  }

  if (gemmaPath == null || gemmaPath.isEmpty) {
    test('Gemma injection cases', () {}, skip: 'set RAMBLE_GEMMA_MODEL to a .litertlm file to run');
  } else {
    final variant = ModelCatalog.byId(Platform.environment['RAMBLE_GEMMA_VARIANT']) ?? ModelCatalog.defaultVariant;
    final gemma = GemmaEngine(variant: variant, modelPath: () async => gemmaPath);
    tearDownAll(gemma.release);
    _runCases('Gemma', () => gemma);
  }
}
