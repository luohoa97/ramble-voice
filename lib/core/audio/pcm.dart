// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

/// The single audio format used everywhere in Ramble Voice: 16 kHz, mono,
/// signed 16-bit little-endian PCM. Gemma 4 (via flutter_edge_ai) wants a
/// 16 kHz mono WAV and Gemini accepts WAV, so capture once and reuse.
abstract final class Pcm {
  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int bitsPerSample = 16;
  static const int bytesPerSample = bitsPerSample ~/ 8;
  static const int bytesPerSecond = sampleRate * channels * bytesPerSample;

  /// Duration of [byteLength] bytes of PCM in this format.
  static Duration durationOf(int byteLength) => Duration(
        microseconds: (byteLength ~/ bytesPerSample) * 1000000 ~/ sampleRate,
      );

  /// Number of bytes for [duration] of audio, aligned to whole samples.
  static int bytesFor(Duration duration) =>
      (duration.inMicroseconds * sampleRate ~/ 1000000) * bytesPerSample;

  /// Views little-endian PCM bytes as samples without copying when aligned.
  static Int16List samples(Uint8List pcm) {
    final usable = pcm.lengthInBytes - pcm.lengthInBytes % bytesPerSample;
    if (pcm.offsetInBytes % bytesPerSample == 0 && Endian.host == Endian.little) {
      return pcm.buffer.asInt16List(pcm.offsetInBytes, usable ~/ bytesPerSample);
    }
    final data = ByteData.sublistView(pcm, 0, usable);
    return Int16List.fromList([
      for (var i = 0; i < usable; i += bytesPerSample)
        data.getInt16(i, Endian.little),
    ]);
  }

  /// Root-mean-square level of a block of PCM, mapped to 0..1 on a
  /// perceptual (dBFS) scale where -60 dBFS and below is 0.
  static double level(Uint8List pcm) {
    final s = samples(pcm);
    if (s.isEmpty) return 0;
    var sum = 0.0;
    for (final v in s) {
      sum += v * v;
    }
    final rms = math.sqrt(sum / s.length) / 32768.0;
    if (rms <= 0) return 0;
    final db = 20 * math.log(rms) / math.ln10;
    return ((db + 60) / 60).clamp(0.0, 1.0);
  }
}

/// Minimal RIFF/WAVE encoder for [Pcm] audio.
abstract final class WavEncoder {
  static const int headerLength = 44;

  static Uint8List encode(Uint8List pcm) {
    final dataLength = pcm.lengthInBytes - pcm.lengthInBytes % Pcm.bytesPerSample;
    final out = Uint8List(headerLength + dataLength);
    final h = ByteData.sublistView(out, 0, headerLength);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        h.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    h.setUint32(4, 36 + dataLength, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    h.setUint32(16, 16, Endian.little); // fmt chunk size
    h.setUint16(20, 1, Endian.little); // PCM
    h.setUint16(22, Pcm.channels, Endian.little);
    h.setUint32(24, Pcm.sampleRate, Endian.little);
    h.setUint32(28, Pcm.bytesPerSecond, Endian.little);
    h.setUint16(32, Pcm.channels * Pcm.bytesPerSample, Endian.little);
    h.setUint16(34, Pcm.bitsPerSample, Endian.little);
    ascii(36, 'data');
    h.setUint32(40, dataLength, Endian.little);
    out.setRange(headerLength, headerLength + dataLength, pcm);
    return out;
  }

  /// Extracts the PCM payload of a WAV produced by [encode]. Accepts any
  /// 16 kHz mono 16-bit PCM WAV with a standard chunk layout.
  static Uint8List decode(Uint8List wav) {
    final d = ByteData.sublistView(wav);
    String tag(int o) => String.fromCharCodes(wav.sublist(o, o + 4));
    if (wav.length < headerLength || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
      throw const FormatException('Not a RIFF/WAVE file');
    }
    var offset = 12;
    int? channels, rate, bits;
    while (offset + 8 <= wav.length) {
      final id = tag(offset);
      final size = d.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ') {
        channels = d.getUint16(body + 2, Endian.little);
        rate = d.getUint32(body + 4, Endian.little);
        bits = d.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        if (channels != Pcm.channels || rate != Pcm.sampleRate || bits != Pcm.bitsPerSample) {
          throw FormatException('Unsupported WAV format: $channels ch, $rate Hz, $bits bit');
        }
        final end = math.min(body + size, wav.length);
        return Uint8List.fromList(wav.sublist(body, end));
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    throw const FormatException('WAV has no data chunk');
  }
}
