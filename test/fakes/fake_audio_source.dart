// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:ramble_voice/core/audio/audio_source.dart';

class FakeAudioCapture implements AudioCapture {
  final _controller = StreamController<Uint8List>();
  bool stopped = false;

  /// Runs inside [stop] before the stream closes; use it to emit blocks that
  /// arrive while the controller is stopping.
  void Function(FakeAudioCapture capture)? onStop;

  @override
  Stream<Uint8List> get pcm => _controller.stream;

  void emit(Uint8List block) => _controller.add(block);
  void emitError(Object error) => _controller.addError(error);

  @override
  Future<void> stop() async {
    if (stopped) return;
    stopped = true;
    onStop?.call(this);
    await _controller.close();
  }
}

/// Scripted microphone: permission flags, start errors and a capture the
/// test drives with [FakeAudioCapture.emit].
class FakeAudioSource implements AudioSource {
  FakeAudioSource({
    this.permission = true,
    this.grantsOnRequest = true,
    this.startError,
  });

  bool permission;
  bool grantsOnRequest;

  /// Thrown from [start] when set.
  Object? startError;

  int startCount = 0;
  int requestCount = 0;
  FakeAudioCapture? capture;

  @override
  String get backendName => 'fake';

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<bool> requestPermission() async {
    requestCount++;
    if (grantsOnRequest) permission = true;
    return permission;
  }

  @override
  Future<AudioCapture> start() async {
    startCount++;
    final error = startError;
    if (error != null) throw error;
    return capture = FakeAudioCapture();
  }
}
