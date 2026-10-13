// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/cleanup/gemma/gemma_engine.dart';
import 'package:ramble_voice/core/models/model_catalog.dart';
import 'package:ramble_voice/core/style/style_profile.dart';

import '../fakes/temp_dirs.dart';

/// Only the paths that never reach the native runtime.
void main() {
  test('kind and per-request limit', () {
    final e = GemmaEngine(
      variant: ModelCatalog.e2b,
      modelPath: () async => null,
    );
    expect(e.kind, EngineKind.onDevice);
    expect(e.maxAudioPerRequest, ModelCatalog.maxAudioPerRequest);
    expect(e.activeBackend, isNull);
  });

  test('no model path is modelNotDownloaded', () async {
    final e = GemmaEngine(
      variant: ModelCatalog.e4b,
      modelPath: () async => null,
    );
    final r = await e.readiness();
    expect(
      r,
      isA<EngineNotReady>()
          .having(
            (x) => x.reason,
            'reason',
            CleanupFailureKind.modelNotDownloaded,
          )
          .having((x) => x.message, 'message', contains('Gemma 4 E4B')),
    );
  });

  test('a path to a missing file is modelNotDownloaded', () async {
    final dir = await makeTempDir();
    final e = GemmaEngine(
      variant: ModelCatalog.e4b,
      modelPath: () async => '${dir.path}/missing.litertlm',
    );
    expect(await e.readiness(), isA<EngineNotReady>());
  });

  test('process without a model fails with modelNotDownloaded before touching native code', () async {
    final e = GemmaEngine(
      variant: ModelCatalog.e4b,
      modelPath: () async => null,
    );
    await expectLater(
      e.process(
        CleanupRequest(pcm: Uint8List(3200), style: const StyleProfile()),
      ),
      throwsA(
        isA<CleanupFailure>().having(
          (f) => f.kind,
          'kind',
          CleanupFailureKind.modelNotDownloaded,
        ),
      ),
    );
  });

  test('an existing file is reported ready with the variant label', () async {
    final dir = await makeTempDir();
    final f = File('${dir.path}/m.litertlm')..writeAsBytesSync([1]);
    final e = GemmaEngine(
      variant: ModelCatalog.e2b,
      modelPath: () async => f.path,
    );
    expect(
      await e.readiness(),
      isA<EngineReady>().having((r) => r.detail, 'detail', 'Gemma 4 E2B'),
    );
  });

  test('release without a loaded model is harmless', () async {
    await GemmaEngine(
      variant: ModelCatalog.e2b,
      modelPath: () async => null,
    ).release();
  });
}
