// SPDX-License-Identifier: GPL-3.0-or-later

/// Microphone capture on Linux.
///
/// 1. Native `libramble_capture.so` (PipeWire, with its own PulseAudio
///    fallback) through dart:ffi, polled every 20 ms.
/// 2. `pw-record` reading raw PCM from stdout.
/// 3. `parecord` reading raw PCM from stdout.
///
/// Linux has no microphone permission prompt. Sandboxed (Flatpak) builds get
/// access through `--socket=pulseaudio` in the manifest, so [hasPermission]
/// and [requestPermission] are always true; failures surface from [start] as
/// [AudioSourceException].
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/audio/audio_source.dart';

/// Keeps a byte stream aligned to whole 16-bit samples.
class PcmAligner {
  int? _carry;

  /// Returns [chunk] without a dangling half sample (or null if nothing is
  /// left), remembering that byte for the next call.
  Uint8List? push(Uint8List chunk) {
    var data = chunk;
    if (_carry != null) {
      final merged = Uint8List(chunk.length + 1)
        ..[0] = _carry!
        ..setRange(1, chunk.length + 1, chunk);
      data = merged;
      _carry = null;
    }
    if (data.length.isOdd) {
      _carry = data[data.length - 1];
      data = Uint8List.sublistView(data, 0, data.length - 1);
    }
    return data.isEmpty ? null : data;
  }
}

typedef _NoArgInt = int Function();
typedef _NoArgIntC = Int32 Function();
typedef _ReadC = Int32 Function(Pointer<Uint8>, Int32);
typedef _Read = int Function(Pointer<Uint8>, int);
typedef _StrC = Pointer<Uint8> Function();
typedef _Str = Pointer<Uint8> Function();
typedef _VoidC = Void Function();
typedef _Void = void Function();

class _Native {
  _Native(DynamicLibrary lib)
      : open = lib.lookupFunction<_NoArgIntC, _NoArgInt>('rc_open'),
        start = lib.lookupFunction<_NoArgIntC, _NoArgInt>('rc_start'),
        read = lib.lookupFunction<_ReadC, _Read>('rc_read'),
        stop = lib.lookupFunction<_NoArgIntC, _NoArgInt>('rc_stop'),
        close = lib.lookupFunction<_VoidC, _Void>('rc_close'),
        _backend = lib.lookupFunction<_StrC, _Str>('rc_backend'),
        _lastError = lib.lookupFunction<_StrC, _Str>('rc_last_error');

  final _NoArgInt open, start, stop;
  final _Read read;
  final _Void close;
  final _Str _backend, _lastError;

  String get backend => _cString(_backend());
  String get lastError => _cString(_lastError());

  static String _cString(Pointer<Uint8> ptr) {
    final bytes = <int>[];
    for (var i = 0; i < 1024; i++) {
      final b = ptr[i];
      if (b == 0) break;
      bytes.add(b);
    }
    return String.fromCharCodes(bytes);
  }
}

extension on Pointer<Uint8> {
  Uint8List copy(int length) => Uint8List.fromList(asTypedList(length));
}

@Native<Pointer<Void> Function(IntPtr)>(symbol: 'malloc', isLeaf: true)
external Pointer<Void> _malloc(int size);

@Native<Void Function(Pointer<Void>)>(symbol: 'free', isLeaf: true)
external void _free(Pointer<Void> ptr);

class LinuxAudioSource implements AudioSource {
  LinuxAudioSource({this.libraryPath, this.environment, this.allowNative = true});

  /// Skip libramble_capture and use pw-record/parecord directly (tests).
  final bool allowNative;

  /// Explicit path to libramble_capture.so (tests, unusual layouts). Also
  /// read from `RAMBLE_CAPTURE_LIB`.
  final String? libraryPath;
  final Map<String, String>? environment;

  String _backendName = 'PipeWire';
  bool _active = false;
  _Native? _native;
  bool _nativeTried = false;
  String? _loadedFrom;

  /// Path of the loaded native library, or null when running without it.
  String? get nativeLibraryPath => _loadedFrom;

  @override
  String get backendName => _backendName;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> requestPermission() async => true;

  /// Candidate library locations, best first.
  List<String> libraryCandidates() {
    final env = environment ?? Platform.environment;
    final exeDir = p.dirname(Platform.resolvedExecutable);
    return [
      ?libraryPath,
      if ((env['RAMBLE_CAPTURE_LIB'] ?? '').isNotEmpty) env['RAMBLE_CAPTURE_LIB']!,
      p.join(exeDir, 'lib', 'libramble_capture.so'),
      p.join(exeDir, 'libramble_capture.so'),
      '/app/lib/libramble_capture.so',
      'libramble_capture.so',
    ];
  }

  _Native? _loadNative() {
    if (_nativeTried) return _native;
    _nativeTried = true;
    for (final path in libraryCandidates()) {
      try {
        if (path.contains('/') && !File(path).existsSync()) continue;
        _native = _Native(DynamicLibrary.open(path));
        _loadedFrom = path;
        return _native;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  @override
  Future<AudioCapture> start() async {
    if (_active) throw const AudioSourceException(AudioSourceError.deviceUnavailable, 'Already recording');
    final errors = <String>[];

    final native = allowNative ? _loadNative() : null;
    if (native != null) {
      final cap = _NativeCapture.tryStart(native, errors);
      if (cap != null) {
        _backendName = native.backend == 'pulse' ? 'PulseAudio' : 'PipeWire';
        return _track(cap);
      }
    } else if (allowNative) {
      errors.add('libramble_capture.so not found');
    }

    for (final tool in _processTools) {
      final path = _findBinary(tool.binary);
      if (path == null) {
        errors.add('${tool.binary} not installed');
        continue;
      }
      try {
        final cap = await _ProcessCapture.start(path, tool.args);
        _backendName = tool.binary;
        return _track(cap);
      } on AudioSourceException catch (e) {
        errors.add('${tool.binary}: ${e.detail}');
      }
    }
    throw AudioSourceException(AudioSourceError.backendMissing, errors.join('; '));
  }

  AudioCapture _track(_Capture cap) {
    _active = true;
    cap.onDone = () => _active = false;
    return cap;
  }

  static const _processTools = [
    (binary: 'pw-record', args: ['--rate', '16000', '--channels', '1', '--format', 's16', '--raw', '-']),
    (binary: 'parecord', args: ['--rate=16000', '--channels=1', '--format=s16le', '--raw']),
  ];

  static String? _findBinary(String name) {
    final dirs = [
      ...(Platform.environment['PATH'] ?? '').split(':').where((e) => e.isNotEmpty),
      '/app/bin',
      '/usr/bin',
    ];
    for (final d in dirs) {
      final f = File(p.join(d, name));
      if (f.existsSync()) return f.path;
    }
    return null;
  }
}

abstract class _Capture implements AudioCapture {
  void Function()? onDone;
}

class _NativeCapture extends _Capture {
  _NativeCapture._(this._native, this._buffer) {
    _controller = StreamController<Uint8List>(onCancel: stop);
    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) => _poll());
  }

  static const _blockBytes = 16384;

  static _NativeCapture? tryStart(_Native native, List<String> errors) {
    if (native.open() != 0) {
      errors.add('native: ${native.lastError}');
      return null;
    }
    if (native.start() != 0) {
      errors.add('native: ${native.lastError}');
      native.close();
      return null;
    }
    return _NativeCapture._(native, _malloc(_blockBytes).cast<Uint8>());
  }

  final _Native _native;
  final Pointer<Uint8> _buffer;
  late final StreamController<Uint8List> _controller;
  late final Timer _timer;
  bool _stopped = false;

  @override
  Stream<Uint8List> get pcm => _controller.stream;

  /// Drains everything currently buffered. Returns false on a stream failure.
  bool _drain() {
    while (true) {
      final n = _native.read(_buffer, _blockBytes);
      if (n < 0) return false;
      if (n == 0) return true;
      if (!_controller.isClosed) _controller.add(_buffer.copy(n));
    }
  }

  void _poll() {
    if (_stopped) return;
    if (!_drain()) {
      final detail = _native.lastError;
      _controller.addError(AudioSourceException(AudioSourceError.deviceUnavailable, detail.isEmpty ? 'capture failed' : detail));
      stop();
    }
  }

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _timer.cancel();
    _native.stop();
    _drain();
    _native.close();
    _free(_buffer.cast<Void>());
    if (!_controller.isClosed) unawaited(_controller.close());
    onDone?.call();
  }
}

class _ProcessCapture extends _Capture {
  _ProcessCapture._(this._process) {
    _controller = StreamController<Uint8List>(onCancel: stop);
  }

  static Future<_ProcessCapture> start(String binary, List<String> args) async {
    final Process process;
    try {
      process = await Process.start(binary, args);
    } on ProcessException catch (e) {
      throw AudioSourceException(AudioSourceError.backendMissing, e.message);
    }
    final cap = _ProcessCapture._(process);
    final stderr = StringBuffer();
    process.stderr.transform(const SystemEncoding().decoder).listen(stderr.write, onError: (_) {});

    final first = Completer<void>();
    final aligner = PcmAligner();
    process.stdout.listen((chunk) {
      final aligned = aligner.push(Uint8List.fromList(chunk));
      if (aligned == null) return;
      if (!first.isCompleted) first.complete();
      if (!cap._controller.isClosed) cap._controller.add(aligned);
    }, onDone: () {
      if (!first.isCompleted) first.completeError(AudioSourceException(AudioSourceError.deviceUnavailable, stderr.toString().trim()));
      if (!cap._stopped) cap.stop();
    }, onError: (_) {});

    try {
      await first.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill();
      throw AudioSourceException(AudioSourceError.deviceUnavailable, 'no audio within 3 s ${stderr.toString().trim()}');
    } on AudioSourceException {
      process.kill();
      rethrow;
    }
    return cap;
  }

  final Process _process;
  late final StreamController<Uint8List> _controller;
  bool _stopped = false;

  @override
  Stream<Uint8List> get pcm => _controller.stream;

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _process.kill(ProcessSignal.sigterm);
    if (!_controller.isClosed) unawaited(_controller.close());
    onDone?.call();
  }
}
