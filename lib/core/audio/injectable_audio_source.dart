// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'audio_source.dart';
import 'pcm.dart';

/// Wraps the microphone so an end-to-end test can play a recording into the
/// next capture instead (see `tool/e2e`). Only the debug hook calls [inject];
/// without it this is the plain microphone.
class InjectableAudioSource implements AudioSource {
  InjectableAudioSource(this._inner);

  final AudioSource _inner;
  Uint8List? _pending;
  void Function()? _onEnd;

  /// The next [start] plays [pcm] in real time, then calls [onEnd].
  void inject(Uint8List pcm, {void Function()? onEnd}) {
    _pending = pcm;
    _onEnd = onEnd;
  }

  @override
  String get backendName => _inner.backendName;

  @override
  Future<bool> hasPermission() async => _pending != null || await _inner.hasPermission();

  @override
  Future<bool> requestPermission() => _inner.requestPermission();

  @override
  Future<AudioCapture> start() async {
    final pcm = _pending;
    if (pcm == null) return _inner.start();
    _pending = null;
    final onEnd = _onEnd;
    _onEnd = null;
    return _PlaybackCapture(pcm, onEnd);
  }
}

class _PlaybackCapture implements AudioCapture {
  _PlaybackCapture(Uint8List pcm, void Function()? onEnd) {
    // 30 ms blocks, like the real microphone.
    final block = Pcm.bytesFor(const Duration(milliseconds: 30));
    var offset = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 30), (t) {
      if (_out.isClosed) return t.cancel();
      if (offset >= pcm.length) {
        t.cancel();
        onEnd?.call();
        return;
      }
      final end = (offset + block).clamp(0, pcm.length);
      _out.add(Uint8List.sublistView(pcm, offset, end));
      offset = end;
    });
  }

  final _out = StreamController<Uint8List>();
  late final Timer _timer;

  @override
  Stream<Uint8List> get pcm => _out.stream;

  @override
  Future<void> stop() async {
    _timer.cancel();
    if (!_out.isClosed) await _out.close();
  }
}
