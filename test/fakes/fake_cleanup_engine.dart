// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/style/style_profile.dart';

/// Scripted engine. Each call to [process] consumes the next script entry:
/// a [String] is returned, a [CleanupFailure] (or any Object) is thrown, a
/// `Future<String> Function(CleanupRequest)` is awaited. When the script is
/// exhausted, [defaultResult] is returned.
class FakeCleanupEngine implements CleanupEngine {
  FakeCleanupEngine({
    this.kind = EngineKind.gemini,
    this.maxAudioPerRequest = const Duration(minutes: 7),
    List<Object> script = const [],
    this.defaultResult = 'cleaned text',
    this.ready = const EngineReady(),
  }) : script = List.of(script);

  @override
  final EngineKind kind;
  @override
  final Duration maxAudioPerRequest;

  final List<Object> script;
  final String defaultResult;
  EngineReadiness ready;

  final List<CleanupRequest> requests = [];
  int released = 0;

  List<int> get pcmLengths => [for (final r in requests) r.pcm.length];
  List<CleanupMode> get modes => [for (final r in requests) r.mode];
  List<StyleProfile> get styles => [for (final r in requests) r.style];

  @override
  Future<EngineReadiness> readiness() async => ready;

  @override
  Future<String> process(CleanupRequest request) async {
    requests.add(request);
    if (script.isEmpty) return defaultResult;
    final next = script.removeAt(0);
    if (next is String) return next;
    if (next is Future<String> Function(CleanupRequest)) return next(request);
    throw next;
  }

  @override
  Future<void> release() async => released++;
}
