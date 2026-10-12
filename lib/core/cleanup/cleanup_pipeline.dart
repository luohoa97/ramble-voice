// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import '../audio/chunker.dart';
import '../audio/auto_gain.dart';
import '../audio/pcm.dart';
import '../style/style_profile.dart';
import 'cleanup_engine.dart';

class PipelineProgress {
  const PipelineProgress({
    required this.engine,
    required this.chunk,
    required this.chunks,
    this.fellBack = false,
  });

  final EngineKind engine;

  /// 1-based index of the chunk being processed.
  final int chunk;
  final int chunks;
  final bool fellBack;
}

class PipelineResult {
  const PipelineResult({
    required this.text,
    required this.engine,
    this.fallbackReason,
    this.chunks = 1,
  });

  final String text;
  final EngineKind engine;

  /// Set when the primary engine failed and [engine] is the fallback.
  final CleanupFailure? fallbackReason;
  final int chunks;

  bool get fellBack => fallbackReason != null;
}

/// Runs a whole recording through an engine: chunks it to the engine's
/// per-request limit, cleans each chunk, stitches the text, and falls back to
/// a second engine (on-device Gemma) when the cloud engine is rate limited,
/// offline or out of quota.
class CleanupPipeline {
  const CleanupPipeline({this.searchWindow = const Duration(seconds: 6)});

  final Duration searchWindow;

  Future<PipelineResult> run({
    required Uint8List pcm,
    required StyleProfile style,
    required CleanupEngine primary,
    CleanupEngine? fallback,
    CleanupMode mode = CleanupMode.clean,
    String? contextBefore,
    String? contextAfter,
    void Function(PipelineProgress)? onProgress,
  }) async {
    pcm = AutoGain.normalize(pcm);
    try {
      return await _runWith(primary, pcm, style, mode, onProgress,
          fellBack: false, contextBefore: contextBefore, contextAfter: contextAfter);
    } on CleanupFailure catch (failure) {
      if (fallback == null || !failure.kind.cloudFallbackEligible || fallback.kind == primary.kind) {
        rethrow;
      }
      final ready = await fallback.readiness();
      if (ready is! EngineReady) rethrow;
      final result = await _runWith(fallback, pcm, style, mode, onProgress,
          fellBack: true, contextBefore: contextBefore, contextAfter: contextAfter);
      return PipelineResult(
        text: result.text,
        engine: fallback.kind,
        fallbackReason: failure,
        chunks: result.chunks,
      );
    }
  }

  /// Applies a spoken editing instruction ([pcm]) to [sourceText]. One request,
  /// never chunked: an instruction longer than the engine accepts fails with
  /// [CleanupFailureKind.audioTooLong]. Falls back like [run].
  Future<PipelineResult> edit({
    required Uint8List pcm,
    required String sourceText,
    required StyleProfile style,
    required CleanupEngine primary,
    CleanupEngine? fallback,
  }) async {
    pcm = AutoGain.normalize(pcm);
    try {
      return await _editWith(primary, pcm, sourceText, style);
    } on CleanupFailure catch (failure) {
      if (fallback == null || !failure.kind.cloudFallbackEligible || fallback.kind == primary.kind) {
        rethrow;
      }
      final ready = await fallback.readiness();
      if (ready is! EngineReady) rethrow;
      final result = await _editWith(fallback, pcm, sourceText, style);
      return PipelineResult(text: result.text, engine: fallback.kind, fallbackReason: failure);
    }
  }

  Future<PipelineResult> _editWith(
    CleanupEngine engine,
    Uint8List pcm,
    String sourceText,
    StyleProfile style,
  ) async {
    if (pcm.isEmpty) {
      throw const CleanupFailure(CleanupFailureKind.emptyResult, 'The recording is empty.');
    }
    if (Pcm.durationOf(pcm.length) > engine.maxAudioPerRequest) {
      throw const CleanupFailure(CleanupFailureKind.audioTooLong, 'The instruction is too long. Keep it short.');
    }
    final text = (await engine.process(CleanupRequest(
      pcm: pcm,
      style: style,
      mode: CleanupMode.edit,
      sourceText: sourceText,
    )))
        .trim();
    if (text.isEmpty) {
      throw const CleanupFailure(CleanupFailureKind.emptyResult, 'No edit was returned.');
    }
    return PipelineResult(text: text, engine: engine.kind);
  }

  /// The field text plus the chunks cleaned so far, as the context for the
  /// next chunk.
  static String _continuation(String? fieldBefore, List<String> parts) {
    final written = TextStitcher.join(parts);
    final base = fieldBefore ?? '';
    final glue = base.isEmpty || written.isEmpty || RegExp(r'\s$').hasMatch(base) ? '' : ' ';
    return '$base$glue$written';
  }

  Future<PipelineResult> _runWith(
    CleanupEngine engine,
    Uint8List pcm,
    StyleProfile style,
    CleanupMode mode,
    void Function(PipelineProgress)? onProgress, {
    required bool fellBack,
    String? contextBefore,
    String? contextAfter,
  }) async {
    final limit = engine.maxAudioPerRequest;
    final window = searchWindow < limit ~/ 2 ? searchWindow : limit ~/ 4;
    final spans = SilenceChunker(maxChunk: limit, searchWindow: window).plan(pcm);
    if (spans.isEmpty) {
      throw const CleanupFailure(CleanupFailureKind.emptyResult, 'The recording is empty.');
    }
    final parts = <String>[];
    for (var i = 0; i < spans.length; i++) {
      onProgress?.call(PipelineProgress(
        engine: engine.kind,
        chunk: i + 1,
        chunks: spans.length,
        fellBack: fellBack,
      ));
      final span = spans[i];
      // The first chunk continues the field's text; each later chunk continues
      // what was just written, so the chunks stitch like one dictation.
      final lastChunk = i == spans.length - 1;
      final before = i == 0 ? contextBefore : _continuation(contextBefore, parts);
      parts.add(await engine.process(CleanupRequest(
        pcm: Uint8List.sublistView(pcm, span.start, span.end),
        style: style,
        mode: mode,
        contextBefore: before,
        contextAfter: lastChunk ? contextAfter : null,
      )));
    }
    final text = TextStitcher.join(parts);
    if (text.isEmpty) {
      throw const CleanupFailure(CleanupFailureKind.emptyResult, 'No speech was recognised.');
    }
    return PipelineResult(text: text, engine: engine.kind, chunks: spans.length);
  }
}
