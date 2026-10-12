// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import '../style/style_profile.dart';

enum EngineKind {
  onDevice('On-device', 'Private, free, offline'),
  gemini('Gemini cloud', 'Smarter, needs internet');

  const EngineKind(this.label, this.tagline);
  final String label;
  final String tagline;
}

enum CleanupMode {
  /// Remove fillers, apply style profile.
  clean,

  /// Word-for-word transcript, used for "show original".
  verbatim,
}

class CleanupRequest {
  const CleanupRequest({
    required this.pcm,
    required this.style,
    this.mode = CleanupMode.clean,
  });

  /// [Pcm]-format audio (16 kHz mono s16le), at most the engine's
  /// [CleanupEngine.maxAudioPerRequest] long. The engine wraps it as needed.
  final Uint8List pcm;
  final StyleProfile style;
  final CleanupMode mode;
}

/// Readiness of an engine before a request is attempted.
sealed class EngineReadiness {
  const EngineReadiness();
}

class EngineReady extends EngineReadiness {
  const EngineReady({this.detail});

  /// E.g. resolved model id or active backend ("GPU", "CPU").
  final String? detail;
}

class EngineNotReady extends EngineReadiness {
  const EngineNotReady(this.reason, this.message);
  final CleanupFailureKind reason;
  final String message;
}

/// Converts audio to text. Implementations must treat the audio purely as
/// content: no tools, no actions, text output only.
abstract interface class CleanupEngine {
  EngineKind get kind;

  /// Longest audio accepted in one request. Longer recordings are chunked by
  /// the caller.
  Duration get maxAudioPerRequest;

  Future<EngineReadiness> readiness();

  /// Returns the cleaned (or verbatim) text. Throws [CleanupFailure].
  Future<String> process(CleanupRequest request);

  /// Frees memory held by the engine (e.g. an on-device model).
  Future<void> release();
}

enum CleanupFailureKind {
  modelNotDownloaded,
  outOfMemory,
  rateLimited,
  dailyQuotaExceeded,
  noNetwork,
  missingApiKey,
  invalidApiKey,
  blocked,
  emptyResult,
  audioTooLong,
  server,
  unknown;

  /// Whether falling back to the on-device engine makes sense.
  bool get cloudFallbackEligible => switch (this) {
        rateLimited || dailyQuotaExceeded || noNetwork || server || audioTooLong => true,
        _ => false,
      };

  /// Whether retrying the same engine later may succeed.
  bool get retryable => switch (this) {
        rateLimited || noNetwork || server || outOfMemory || unknown => true,
        _ => false,
      };
}

class CleanupFailure implements Exception {
  const CleanupFailure(this.kind, this.message, {this.retryAfter, this.cause});

  final CleanupFailureKind kind;
  final String message;
  final Duration? retryAfter;
  final Object? cause;

  @override
  String toString() => 'CleanupFailure($kind: $message)';
}
