// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import '../audio/audio_source.dart';
import '../audio/pcm.dart';
import '../cleanup/cleanup_engine.dart';
import '../cleanup/cleanup_pipeline.dart';
import '../style/style_profile.dart';
import 'recording_vault.dart';

class DictationOutcome {
  const DictationOutcome({
    required this.recordingId,
    required this.text,
    required this.engine,
    required this.duration,
    required this.createdAt,
    this.fallbackReason,
  });

  final String recordingId;
  final String text;
  final EngineKind engine;
  final Duration duration;
  final DateTime createdAt;
  final CleanupFailure? fallbackReason;

  bool get fellBack => fallbackReason != null;
}

sealed class DictationState {
  const DictationState();
}

class DictationIdle extends DictationState {
  const DictationIdle({this.notice});

  /// One-off message, e.g. "Nothing was recorded".
  final String? notice;
}

class DictationStarting extends DictationState {
  const DictationStarting();
}

class DictationListening extends DictationState {
  const DictationListening({
    required this.elapsed,
    required this.level,
    required this.limit,
    required this.warnBefore,
  });

  final Duration elapsed;

  /// Latest input level, 0..1.
  final double level;

  /// Recording stops and is processed automatically at this length.
  final Duration limit;
  final Duration warnBefore;

  Duration get remaining => limit - elapsed;

  /// True when the UI should warn that the limit is close.
  bool get nearLimit => remaining <= warnBefore;
}

class DictationProcessing extends DictationState {
  const DictationProcessing({required this.recordingId, this.progress});
  final String recordingId;
  final PipelineProgress? progress;
}

class DictationDone extends DictationState {
  const DictationDone(this.outcome);
  final DictationOutcome outcome;
}

class DictationFailed extends DictationState {
  const DictationFailed({
    required this.message,
    this.kind,
    this.audioError,
    this.recordingId,
    this.retryAfter,
  });

  final String message;
  final CleanupFailureKind? kind;
  final AudioSourceError? audioError;

  /// Set when audio was captured and kept; the user can retry later.
  final String? recordingId;
  final Duration? retryAfter;

  bool get canRetry => recordingId != null;
}

class EngineSet {
  const EngineSet(this.primary, [this.fallback]);
  final CleanupEngine primary;
  final CleanupEngine? fallback;
}

/// The dictation state machine shared by the main app, the Android keyboard
/// and the Linux hotkey flow:
///
/// idle → starting → listening → processing → done | failed
///
/// Audio is streamed to [RecordingVault] while listening, so a crash, error
/// or killed process never loses the recording.
class DictationController {
  DictationController({
    required this.audio,
    required this.vault,
    required this.engines,
    required this.style,
    this.onOutcome,
    this.pipeline = const CleanupPipeline(),
    this.maxSession = const Duration(minutes: 10),
    this.warnBefore = const Duration(seconds: 30),
    this.minSpeech = const Duration(milliseconds: 400),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AudioSource audio;
  final RecordingVault vault;
  final Future<EngineSet> Function() engines;
  /// May be async, e.g. to read the address book.
  final FutureOr<StyleProfile> Function() style;

  /// Called after a successful cleanup, before the state becomes done
  /// (history save, text insertion).
  final Future<void> Function(DictationOutcome outcome)? onOutcome;
  final CleanupPipeline pipeline;
  final Duration maxSession;
  final Duration warnBefore;
  final Duration minSpeech;
  final DateTime Function() _clock;

  final _states = StreamController<DictationState>.broadcast(sync: true);
  DictationState _state = const DictationIdle();

  AudioCapture? _capture;
  StreamSubscription<Uint8List>? _sub;
  RecordingSink? _sink;
  DateTime? _startedAt;
  Completer<void>? _captureDone;

  DictationState get state => _state;
  Stream<DictationState> get states => _states.stream;

  bool get isBusy => _state is DictationStarting || _state is DictationListening || _state is DictationProcessing;

  void _emit(DictationState s) {
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  /// Tap-to-toggle: start when idle, stop and process when listening.
  Future<void> toggle() async {
    switch (_state) {
      case DictationListening():
        await stop();
      case DictationIdle() || DictationDone() || DictationFailed():
        await start();
      case DictationProcessing():
        await cancelProcessing();
      case DictationStarting():
        break;
    }
  }

  /// Bumped whenever a running cleanup is cancelled; a cleanup whose token is
  /// stale finishes silently.
  int _processToken = 0;

  /// Stops waiting for the current cleanup (e.g. the network or model hangs).
  /// The recording is kept as pending, so it can be retried from History; a
  /// late result from the engine is ignored.
  Future<void> cancelProcessing() async {
    if (_state is! DictationProcessing) return;
    _processToken++;
    _emit(const DictationIdle(notice: 'Cancelled. The recording is saved; retry it from the app.'));
  }

  Future<void> start() async {
    if (isBusy) return;
    _emit(const DictationStarting());
    try {
      if (!await audio.hasPermission() && !await audio.requestPermission()) {
        throw const AudioSourceException(AudioSourceError.permissionDenied);
      }
      _sink = await vault.begin(now: _clock());
      _startedAt = _clock();
      _captureDone = Completer<void>();
      _capture = await audio.start();
    } on AudioSourceException catch (e) {
      await _discardSink();
      _emit(DictationFailed(message: _audioMessage(e.error), audioError: e.error));
      return;
    } catch (e) {
      await _discardSink();
      _emit(DictationFailed(
        message: 'The microphone could not start.',
        audioError: AudioSourceError.deviceUnavailable,
      ));
      return;
    }
    _emit(DictationListening(
      elapsed: Duration.zero,
      level: 0,
      limit: maxSession,
      warnBefore: warnBefore,
    ));
    _sub = _capture!.pcm.listen(
      _onPcm,
      onDone: () => _captureDone?.complete(),
      onError: (Object _) => _captureDone?.complete(),
      cancelOnError: true,
    );
  }

  void _onPcm(Uint8List block) {
    final sink = _sink;
    if (sink == null) return;
    sink.add(block);
    // Blocks that arrive while stopping are kept but don't update the UI.
    if (_state is! DictationListening) return;
    final elapsed = Pcm.durationOf(sink.bytesWritten);
    _emit(DictationListening(
      elapsed: elapsed,
      level: Pcm.level(block),
      limit: maxSession,
      warnBefore: warnBefore,
    ));
    if (elapsed >= maxSession) unawaited(stop());
  }

  /// Stops capture and processes the recording.
  Future<void> stop() async {
    if (_state is! DictationListening) return;
    final sink = _sink!;
    _emit(DictationProcessing(recordingId: sink.id));
    await _stopCapture();
    _sink = null;
    await sink.close();
    if (Pcm.durationOf(sink.bytesWritten) < minSpeech) {
      await vault.delete(sink.id);
      _emit(const DictationIdle(notice: 'Nothing was recorded.'));
      return;
    }
    await _process(sink.id);
  }

  /// Stops capture and throws the audio away.
  Future<void> cancel() async {
    final sink = _sink;
    if (_state is DictationListening || _state is DictationStarting) {
      await _stopCapture();
      await sink?.close();
      if (sink != null) await vault.delete(sink.id);
      _sink = null;
      _emit(const DictationIdle());
    }
  }

  /// Stops capture without processing and keeps the audio as a pending
  /// recording (offered for retry later). Used when the host is going away,
  /// e.g. the keyboard service is destroyed mid-dictation. Never discards.
  Future<void> abandon() async {
    final sink = _sink;
    if (_state is DictationListening || _state is DictationStarting) {
      await _stopCapture();
      _sink = null;
      await sink?.close();
      if (sink != null && sink.bytesWritten < Pcm.bytesFor(minSpeech)) await vault.delete(sink.id);
      _emit(const DictationIdle(notice: 'Recording saved. Retry it from the app.'));
    }
  }

  /// Re-runs cleanup on a kept recording (after an error or for a pending
  /// recording found at startup).
  Future<void> retry([String? recordingId]) async {
    final id = recordingId ?? switch (_state) { DictationFailed(:final recordingId) => recordingId, _ => null };
    if (id == null || isBusy) return;
    _emit(DictationProcessing(recordingId: id));
    await _process(id);
  }

  /// Returns to idle after a result or error has been shown.
  void reset() {
    if (!isBusy) _emit(const DictationIdle());
  }

  Future<void> _process(String id) async {
    final token = ++_processToken;
    bool cancelled() => token != _processToken;
    final pcm = await vault.read(id);
    if (pcm == null) {
      _emit(const DictationFailed(message: 'The recording could not be found.'));
      return;
    }
    try {
      final set = await engines();
      final result = await pipeline.run(
        pcm: pcm,
        style: await style(),
        primary: set.primary,
        fallback: set.fallback,
        onProgress: (p) {
          if (!cancelled()) _emit(DictationProcessing(recordingId: id, progress: p));
        },
      );
      if (cancelled()) return;
      final outcome = DictationOutcome(
        recordingId: id,
        text: result.text,
        engine: result.engine,
        duration: Pcm.durationOf(pcm.length),
        createdAt: _startedAt ?? _clock(),
        fallbackReason: result.fallbackReason,
      );
      await vault.markProcessed(id);
      await onOutcome?.call(outcome);
      _emit(DictationDone(outcome));
    } on CleanupFailure catch (f) {
      if (cancelled()) return;
      _emit(DictationFailed(
        message: f.message,
        kind: f.kind,
        recordingId: id,
        retryAfter: f.retryAfter,
      ));
    } catch (e) {
      if (cancelled()) return;
      _emit(DictationFailed(
        message: 'Cleanup failed unexpectedly. Your recording is saved.',
        kind: CleanupFailureKind.unknown,
        recordingId: id,
      ));
    }
  }

  Future<void> _stopCapture() async {
    final capture = _capture;
    _capture = null;
    if (capture != null) {
      try {
        await capture.stop();
        // Let buffered blocks drain into the sink before closing it.
        await _captureDone?.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      } catch (_) {}
    }
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> _discardSink() async {
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      await sink.close();
      await vault.delete(sink.id);
    }
  }

  static String _audioMessage(AudioSourceError e) => switch (e) {
        AudioSourceError.permissionDenied => 'Microphone access is off. Allow it to dictate.',
        AudioSourceError.deviceUnavailable => 'No microphone is available.',
        AudioSourceError.backendMissing => 'Audio capture is not available on this system.',
      };

  Future<void> dispose() async {
    await cancel();
    await _states.close();
  }
}
