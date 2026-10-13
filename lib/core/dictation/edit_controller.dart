// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import '../audio/audio_source.dart';
import '../audio/pcm.dart';
import '../cleanup/cleanup_engine.dart';
import '../cleanup/cleanup_pipeline.dart';
import '../style/style_profile.dart';
import 'dictation_controller.dart' show EngineSet;

/// The result of one voice edit. The caller replaces [original] with
/// [revised] and keeps [original] for undo.
class EditOutcome {
  const EditOutcome({
    required this.original,
    required this.revised,
    required this.engine,
    required this.duration,
    this.fallbackReason,
  });

  final String original;
  final String revised;
  final EngineKind engine;

  /// Length of the spoken instruction.
  final Duration duration;
  final CleanupFailure? fallbackReason;

  bool get fellBack => fallbackReason != null;

  /// False when the model left the text as it was (instruction unclear).
  bool get changed => revised != original;
}

sealed class EditState {
  const EditState();
}

class EditIdle extends EditState {
  const EditIdle({this.notice});
  final String? notice;
}

class EditStarting extends EditState {
  const EditStarting();
}

class EditListening extends EditState {
  const EditListening({
    required this.elapsed,
    required this.level,
    required this.limit,
  });
  final Duration elapsed;

  /// Latest input level, 0..1.
  final double level;
  final Duration limit;
}

class EditProcessing extends EditState {
  const EditProcessing();
}

class EditDone extends EditState {
  const EditDone(this.outcome);
  final EditOutcome outcome;
}

class EditFailed extends EditState {
  const EditFailed({
    required this.message,
    this.kind,
    this.audioError,
    this.canRetry = false,
    this.retryAfter,
  });
  final String message;
  final CleanupFailureKind? kind;
  final AudioSourceError? audioError;

  /// The instruction audio is still held, so [EditController.retry] works.
  final bool canRetry;
  final Duration? retryAfter;
}

/// "Edit what you said by voice". The only place spoken instructions are
/// honoured, and only when the user starts it with [startEdit] (a deliberate,
/// separate action from dictation). The engines receive the source text and
/// the instruction audio and may only return revised text: no tools, no
/// actions.
///
/// idle → starting → listening → processing → done | failed
///
/// The instruction audio is short and held in memory only; it is never
/// written to the recording vault, so it cannot show up as a pending
/// dictation, and it is dropped as soon as the edit finishes.
class EditController {
  EditController({
    required this.audio,
    required this.engines,
    required this.style,
    this.pipeline = const CleanupPipeline(),
    this.isBlocked,
    this.maxInstruction = const Duration(seconds: 60),
    this.minSpeech = const Duration(milliseconds: 300),
    this.maxSourceLength = 12000,
  });

  final AudioSource audio;
  final Future<EngineSet> Function() engines;
  final FutureOr<StyleProfile> Function() style;
  final CleanupPipeline pipeline;

  /// True while something else (dictation) is using the microphone.
  final bool Function()? isBlocked;
  final Duration maxInstruction;
  final Duration minSpeech;
  final int maxSourceLength;

  final _states = StreamController<EditState>.broadcast(sync: true);
  EditState _state = const EditIdle();

  AudioCapture? _capture;
  StreamSubscription<Uint8List>? _sub;
  Completer<void>? _captureDone;
  BytesBuilder? _buffer;
  String? _source;
  Uint8List? _heldPcm;

  EditState get state => _state;
  Stream<EditState> get states => _states.stream;

  bool get isBusy =>
      _state is EditStarting ||
      _state is EditListening ||
      _state is EditProcessing;

  /// The text being edited, while an edit is in progress or just finished.
  String? get sourceText => _source;
  String? _contextBefore;
  String? _contextAfter;

  void _emit(EditState s) {
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  /// Starts listening for the editing instruction to apply to [sourceText].
  /// [contextBefore] and [contextAfter] are the text around it when it is a
  /// selection; they guide the edit but are never changed.
  Future<void> startEdit(
    String sourceText, {
    String? contextBefore,
    String? contextAfter,
  }) async {
    if (isBusy) return;
    if (isBlocked?.call() ?? false) {
      _emit(const EditIdle(notice: 'Finish the dictation first.'));
      return;
    }
    if (sourceText.trim().isEmpty) {
      _emit(const EditIdle(notice: 'There is no text to edit.'));
      return;
    }
    if (sourceText.length > maxSourceLength) {
      _emit(
        const EditFailed(
          message:
              'That text is too long to edit by voice. Select a shorter part.',
        ),
      );
      return;
    }
    _source = sourceText;
    _contextBefore = contextBefore;
    _contextAfter = contextAfter;
    _heldPcm = null;
    _emit(const EditStarting());
    try {
      if (!await audio.hasPermission() && !await audio.requestPermission()) {
        throw const AudioSourceException(AudioSourceError.permissionDenied);
      }
      _buffer = BytesBuilder(copy: false);
      _captureDone = Completer<void>();
      _capture = await audio.start();
    } on AudioSourceException catch (e) {
      _buffer = null;
      _emit(EditFailed(message: _audioMessage(e.error), audioError: e.error));
      return;
    } catch (_) {
      _buffer = null;
      _emit(
        const EditFailed(
          message: 'The microphone could not start.',
          audioError: AudioSourceError.deviceUnavailable,
        ),
      );
      return;
    }
    _emit(
      EditListening(elapsed: Duration.zero, level: 0, limit: maxInstruction),
    );
    _sub = _capture!.pcm.listen(
      _onPcm,
      onDone: () => _captureDone?.complete(),
      onError: (Object _) => _captureDone?.complete(),
      cancelOnError: true,
    );
  }

  /// Tap-to-toggle while the instruction is being spoken.
  Future<void> stop() async {
    if (_state is! EditListening) return;
    _emit(const EditProcessing());
    await _stopCapture();
    final pcm = _buffer?.takeBytes() ?? Uint8List(0);
    _buffer = null;
    if (Pcm.durationOf(pcm.length) < minSpeech) {
      _source = null;
      _emit(const EditIdle(notice: 'Nothing was recorded.'));
      return;
    }
    _heldPcm = pcm;
    await _process();
  }

  /// Stops listening and drops the audio.
  Future<void> cancel() async {
    if (_state is EditListening || _state is EditStarting) {
      await _stopCapture();
      _buffer = null;
      _source = null;
      _emit(const EditIdle());
    }
  }

  /// Re-runs the edit with the instruction audio already captured.
  Future<void> retry() async {
    if (isBusy || _heldPcm == null || _source == null) return;
    _emit(const EditProcessing());
    await _process();
  }

  /// Returns to idle and forgets the text and audio.
  void reset() {
    if (isBusy) return;
    _source = null;
    _heldPcm = null;
    _emit(const EditIdle());
  }

  void _onPcm(Uint8List block) {
    final buffer = _buffer;
    if (buffer == null) return;
    buffer.add(block);
    if (_state is! EditListening) return;
    final elapsed = Pcm.durationOf(buffer.length);
    _emit(
      EditListening(
        elapsed: elapsed,
        level: Pcm.level(block),
        limit: maxInstruction,
      ),
    );
    if (elapsed >= maxInstruction) unawaited(stop());
  }

  Future<void> _process() async {
    final pcm = _heldPcm!;
    final source = _source!;
    try {
      final set = await engines();
      final result = await pipeline.edit(
        pcm: pcm,
        sourceText: source,
        style: await style(),
        primary: set.primary,
        fallback: set.fallback,
        contextBefore: _contextBefore,
        contextAfter: _contextAfter,
      );
      _heldPcm = null;
      _emit(
        EditDone(
          EditOutcome(
            original: source,
            revised: result.text,
            engine: result.engine,
            duration: Pcm.durationOf(pcm.length),
            fallbackReason: result.fallbackReason,
          ),
        ),
      );
    } on CleanupFailure catch (f) {
      _emit(
        EditFailed(
          message: f.message,
          kind: f.kind,
          canRetry: f.kind.retryable,
          retryAfter: f.retryAfter,
        ),
      );
    } catch (_) {
      _emit(
        const EditFailed(
          message: 'The edit failed unexpectedly.',
          kind: CleanupFailureKind.unknown,
          canRetry: true,
        ),
      );
    }
  }

  Future<void> _stopCapture() async {
    final capture = _capture;
    _capture = null;
    if (capture != null) {
      try {
        await capture.stop();
        await _captureDone?.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      } catch (_) {}
    }
    await _sub?.cancel();
    _sub = null;
  }

  static String _audioMessage(AudioSourceError e) => switch (e) {
    AudioSourceError.permissionDenied =>
      'Microphone access is off. Allow it to edit by voice.',
    AudioSourceError.deviceUnavailable => 'No microphone is available.',
    AudioSourceError.backendMissing =>
      'Audio capture is not available on this system.',
  };

  Future<void> dispose() async {
    await cancel();
    _heldPcm = null;
    await _states.close();
  }
}
