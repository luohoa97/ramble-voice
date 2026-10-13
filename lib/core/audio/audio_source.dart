// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

/// Why capture could not start.
enum AudioSourceError { permissionDenied, deviceUnavailable, backendMissing }

class AudioSourceException implements Exception {
  const AudioSourceException(this.error, [this.detail]);
  final AudioSourceError error;
  final String? detail;

  @override
  String toString() =>
      'AudioSourceException($error${detail == null ? '' : ': $detail'})';
}

/// A running capture. [pcm] emits [Pcm]-formatted blocks (16 kHz mono s16le)
/// until [stop] is called, then closes.
abstract interface class AudioCapture {
  Stream<Uint8List> get pcm;
  Future<void> stop();
}

/// Platform microphone. Implementations:
/// - Linux: native PipeWire through dart:ffi, falling back to `pw-record`.
/// - Android: AudioRecord over a platform channel (works in the app and IME).
abstract interface class AudioSource {
  /// Human-readable backend name for diagnostics ("PipeWire", "pw-record").
  String get backendName;

  Future<bool> hasPermission();

  /// Asks the user for mic access where the platform supports a prompt.
  /// Returns whether access is granted afterwards.
  Future<bool> requestPermission();

  /// Starts capture. Throws [AudioSourceException] on failure.
  Future<AudioCapture> start();
}
