// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/audio/audio_source.dart';

/// Microphone over the Kotlin `AudioCaptureHandler` (`ramble/audio` +
/// `ramble/audio/pcm`). Works in the app and in the keyboard engine.
class AndroidAudioSource implements AudioSource {
  AndroidAudioSource({
    this.canRequestPermission = true,
    MethodChannel? control,
    EventChannel? pcm,
    Future<bool> Function()? requestMicrophone,
  }) : _control = control ?? const MethodChannel('ramble/audio'),
       _pcm = pcm ?? const EventChannel('ramble/audio/pcm'),
       _requestMicrophone = requestMicrophone ?? _defaultRequest;

  /// False in the keyboard engine: permission prompts need an Activity, so the
  /// UI sends the user to the app instead.
  final bool canRequestPermission;
  final MethodChannel _control;
  final EventChannel _pcm;
  final Future<bool> Function() _requestMicrophone;

  /// Whether to use the phone's own voice noise reduction (the call-audio
  /// path with its noise suppressor). Set from the settings at startup.
  bool Function() noiseReduction = _off;
  static bool _off() => false;

  static Future<bool> _defaultRequest() async =>
      (await Permission.microphone.request()).isGranted;

  @override
  String get backendName => 'AudioRecord';

  @override
  Future<bool> hasPermission() async {
    try {
      return await _control.invokeMethod<bool>('hasPermission') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!canRequestPermission) return false;
    if (await hasPermission()) return true;
    try {
      await _requestMicrophone();
    } on Object {
      return false;
    }
    return hasPermission();
  }

  @override
  Future<AudioCapture> start() async {
    // Listen first: the native side only has a sink once Dart is subscribed,
    // and messages on the shared binary messenger are delivered in order.
    final out = StreamController<Uint8List>();
    final sub = _pcm.receiveBroadcastStream().listen(
      (event) {
        if (event is Uint8List) out.add(event);
      },
      onError: (Object e, StackTrace s) {
        if (!out.isClosed) out.addError(e, s);
      },
      onDone: () {
        if (!out.isClosed) unawaited(out.close());
      },
    );
    out.onCancel = () => sub.cancel();

    var started = false;
    try {
      started =
          await _control.invokeMethod<bool>('start', {
            'noiseReduction': noiseReduction(),
          }) ??
          false;
    } on PlatformException {
      started = false;
    }
    if (!started) {
      await sub.cancel();
      // Never awaited: close() only completes once someone listens.
      unawaited(out.close());
      throw AudioSourceException(
        await hasPermission()
            ? AudioSourceError.deviceUnavailable
            : AudioSourceError.permissionDenied,
      );
    }
    return _AndroidCapture(_control, out);
  }
}

class _AndroidCapture implements AudioCapture {
  _AndroidCapture(this._control, this._out);

  final MethodChannel _control;
  final StreamController<Uint8List> _out;

  @override
  Stream<Uint8List> get pcm => _out.stream;

  @override
  Future<void> stop() async {
    try {
      await _control.invokeMethod<void>('stop');
    } on PlatformException {
      // Capture is already gone.
    }
    // Native ends the stream after the last block; don't hang if it doesn't.
    Timer(const Duration(seconds: 1), () {
      if (!_out.isClosed) unawaited(_out.close());
    });
  }
}
