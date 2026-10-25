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

  /// The audio is a spoken editing instruction applied to
  /// [CleanupRequest.sourceText]. Only ever started by an explicit Edit
  /// action, never by normal dictation.
  edit,
}

class CleanupRequest {
  const CleanupRequest({
    required this.pcm,
    required this.style,
    this.mode = CleanupMode.clean,
    this.sourceText,
    this.contextBefore,
    this.contextAfter,
    this.part,
    this.repeated = Duration.zero,
    this.cutWord = false,
    this.screenContext,
    this.fieldInfo,
    this.loudness,
  }) : assert(mode != CleanupMode.edit || sourceText != null, 'edit mode needs sourceText');


  /// [Pcm]-format audio (16 kHz mono s16le), at most the engine's
  /// [CleanupEngine.maxAudioPerRequest] long. The engine wraps it as needed.
  final Uint8List pcm;
  final StyleProfile style;
  final CleanupMode mode;

  /// The text to revise; required for (and only used by) [CleanupMode.edit].
  final String? sourceText;

  /// Text already in the field before the cursor (at most
  /// [contextBeforeLimit] characters, the end of it). Context only.
  final String? contextBefore;

  /// Text after the cursor (at most [contextAfterLimit] characters).
  final String? contextAfter;

  /// 2-based index when this audio is a later part of one long recording
  /// that was split for the engine; null for a whole recording or the first
  /// part. The text written for the earlier parts ends [contextBefore].
  final int? part;

  /// How much audio at the start repeats the end of the previous part, so the
  /// words leading into this part are heard again.
  final Duration repeated;

  /// True when the split fell inside speech: the last word of the previous
  /// part was cut and is missing from [contextBefore].
  final bool cutWord;

  /// Text shown on screen in the app (the conversation being replied to).
  /// Context only, written by other people: never instructions.
  final String? screenContext;

  /// One line describing the field being typed into (app, kind, hint).
  final String? fieldInfo;

  /// How loudly the person spoke, measured before levelling (see
  /// AutoGain.describeLoudness); null when ordinary.
  final String? loudness;

  static const contextBeforeLimit = 500;
  static const screenContextLimit = 1500;
  static const contextAfterLimit = 100;

  /// Whether there is field context: the text to continue from (clean mode)
  /// or the text around a selection being edited (edit mode).
  bool get hasContext =>
      mode != CleanupMode.verbatim &&
      ((contextBefore?.isNotEmpty ?? false) ||
          (contextAfter?.isNotEmpty ?? false) ||
          (screenContext?.isNotEmpty ?? false) ||
          (fieldInfo?.isNotEmpty ?? false));
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

/// An engine that can get ready while the person is still speaking (open a
/// connection, load a model), so the answer comes sooner after they stop.
abstract interface class WarmableEngine {
  /// Never throws.
  Future<void> warmUp();
}

enum CleanupFailureKind {
  modelNotDownloaded,
  outOfMemory,
  rateLimited,
  dailyQuotaExceeded,

  /// The chosen cloud model has no quota on this key's tier (`limit: 0`).
  modelNotOnFreeTier,

  /// The chosen cloud model cannot be used with this key at all (retired for
  /// new users, or it rejects the instructions the app needs).
  modelUnavailable,
  noNetwork,

  /// The cloud model did not answer in time (overloaded or stalled).
  timedOut,
  missingApiKey,
  invalidApiKey,
  blocked,
  emptyResult,
  audioTooLong,
  server,
  unknown;

  /// Whether falling back to the on-device engine makes sense.
  bool get cloudFallbackEligible => switch (this) {
        rateLimited || dailyQuotaExceeded || modelNotOnFreeTier || modelUnavailable || noNetwork || timedOut || server || audioTooLong => true,
        _ => false,
      };

  /// Whether retrying the same engine later may succeed.
  bool get retryable => switch (this) {
        rateLimited || noNetwork || timedOut || server || outOfMemory || unknown => true,
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
