// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ramble_voice/core/audio/pcm.dart';

/// Digital silence of [duration].
Uint8List silencePcm(Duration duration) => Uint8List(Pcm.bytesFor(duration));

/// A sine tone of [duration] at [amplitude] (0..1 of full scale).
Uint8List tonePcm(
  Duration duration, {
  double amplitude = 0.5,
  double hz = 220,
}) {
  final n = Pcm.bytesFor(duration) ~/ Pcm.bytesPerSample;
  final out = Uint8List(n * Pcm.bytesPerSample);
  final d = ByteData.sublistView(out);
  for (var i = 0; i < n; i++) {
    final v =
        math.sin(2 * math.pi * hz * i / Pcm.sampleRate) * amplitude * 32767;
    d.setInt16(i * 2, v.round(), Endian.little);
  }
  return out;
}

Uint8List concatBytes(Iterable<Uint8List> parts) {
  final b = BytesBuilder(copy: false);
  parts.forEach(b.add);
  return b.takeBytes();
}

/// Splits [pcm] into blocks of [block] duration (last one may be shorter).
List<Uint8List> blocksOf(
  Uint8List pcm, {
  Duration block = const Duration(milliseconds: 100),
}) {
  final size = Pcm.bytesFor(block);
  return [
    for (var i = 0; i < pcm.length; i += size)
      Uint8List.sublistView(pcm, i, math.min(i + size, pcm.length)),
  ];
}
