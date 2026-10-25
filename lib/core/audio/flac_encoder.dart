// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'pcm.dart';

/// Lossless FLAC encoder for [Pcm] audio (16 kHz mono 16-bit).
///
/// Speech compresses to roughly half the size of WAV, so a long dictation
/// uploads in about half the time on a phone connection while the model hears
/// exactly the same samples. Uses FLAC's fixed predictors (orders 0 to 4) with
/// partitioned Rice coding, which is most of FLAC's gain at a tiny fraction of
/// the work of LPC.
abstract final class FlacEncoder {
  static const mimeType = 'audio/flac';
  static const blockSize = 4096;
  static const _maxRiceParam = 14;
  static const _maxPartitionOrder = 4;

  static Uint8List encode(Uint8List pcm) {
    final samples = Pcm.samples(pcm);
    final out = _BitWriter(samples.length + 64);
    _writeHeader(out, samples.length);
    var frame = 0;
    for (var start = 0; start < samples.length; start += blockSize) {
      final end = start + blockSize < samples.length ? start + blockSize : samples.length;
      _writeFrame(out, Int16List.sublistView(samples, start, end), frame++);
    }
    return out.takeBytes();
  }

  static void _writeHeader(_BitWriter out, int totalSamples) {
    for (final c in 'fLaC'.codeUnits) {
      out.write(c, 8);
    }
    out
      ..write(1, 1) // last metadata block
      ..write(0, 7) // STREAMINFO
      ..write(34, 24)
      ..write(blockSize, 16) // min block size
      ..write(blockSize, 16) // max block size
      ..write(0, 24) // min frame size: unknown
      ..write(0, 24) // max frame size: unknown
      ..write(Pcm.sampleRate, 20)
      ..write(Pcm.channels - 1, 3)
      ..write(Pcm.bitsPerSample - 1, 5)
      ..write(totalSamples >> 32, 4)
      ..write(totalSamples & 0xffffffff, 32);
    // MD5 of the audio: all zeros means "not computed", which FLAC allows.
    for (var i = 0; i < 16; i++) {
      out.write(0, 8);
    }
  }

  static void _writeFrame(_BitWriter out, Int16List block, int frameNumber) {
    final frameStart = out.byteLength;
    final n = block.length;
    final fullBlock = n == blockSize;
    out
      ..write(0x3ffe, 14) // sync
      ..write(0, 1)
      ..write(0, 1) // fixed block size stream
      ..write(fullBlock ? 12 : 7, 4) // 4096, or "16-bit size follows"
      ..write(5, 4) // 16 kHz
      ..write(0, 4) // mono
      ..write(4, 3) // 16 bits per sample
      ..write(0, 1);
    _writeUtf8Number(out, frameNumber);
    if (!fullBlock) out.write(n - 1, 16);
    out.write(_crc8(out.bytes, frameStart, out.byteLength), 8);

    _writeSubframe(out, block);
    out.alignToByte();
    out.write(_crc16(out.bytes, frameStart, out.byteLength), 16);
  }

  static void _writeSubframe(_BitWriter out, Int16List block) {
    final first = block[0];
    if (block.every((s) => s == first)) {
      out
        ..write(0, 1)
        ..write(0, 6) // CONSTANT
        ..write(0, 1)
        ..write(first & 0xffff, 16);
      return;
    }
    final n = block.length;
    var bestOrder = 0;
    var bestBits = 1 << 62;
    _Residual? best;
    for (var order = 0; order <= 4 && order < n; order++) {
      final r = _Residual.fixed(block, order);
      final bits = order * 16 + r.bits;
      if (bits < bestBits) {
        bestBits = bits;
        bestOrder = order;
        best = r;
      }
    }
    if (best == null || bestBits >= n * 16) {
      out
        ..write(0, 1)
        ..write(1, 6) // VERBATIM
        ..write(0, 1);
      for (final s in block) {
        out.write(s & 0xffff, 16);
      }
      return;
    }
    out
      ..write(0, 1)
      ..write(8 | bestOrder, 6) // FIXED, predictor order
      ..write(0, 1);
    for (var i = 0; i < bestOrder; i++) {
      out.write(block[i] & 0xffff, 16);
    }
    best.writeTo(out);
  }

  /// A frame number in FLAC's UTF-8-like variable-length code.
  static void _writeUtf8Number(_BitWriter out, int v) {
    if (v < 0x80) {
      out.write(v, 8);
      return;
    }
    var bytes = 2;
    while (v >= 1 << (5 * bytes + 1)) {
      bytes++;
    }
    final shift = 6 * (bytes - 1);
    out.write(((0xff00 >> bytes) & 0xff) | (v >> shift), 8);
    for (var s = shift - 6; s >= 0; s -= 6) {
      out.write(0x80 | ((v >> s) & 0x3f), 8);
    }
  }

  static int _crc8(Uint8List data, int from, int to) {
    var crc = 0;
    for (var i = from; i < to; i++) {
      crc ^= data[i];
      for (var b = 0; b < 8; b++) {
        crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xff : (crc << 1) & 0xff;
      }
    }
    return crc;
  }

  static int _crc16(Uint8List data, int from, int to) {
    var crc = 0;
    for (var i = from; i < to; i++) {
      crc ^= data[i] << 8;
      for (var b = 0; b < 8; b++) {
        crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x8005) & 0xffff : (crc << 1) & 0xffff;
      }
    }
    return crc;
  }
}

/// The residual of one fixed predictor, with the cheapest Rice partitioning.
class _Residual {
  _Residual(this.order, this.values, this.partitionOrder, this.params, this.bits);

  factory _Residual.fixed(Int16List s, int order) {
    final n = s.length;
    final values = Int32List(n - order);
    for (var i = order; i < n; i++) {
      final int predicted = switch (order) {
        0 => 0,
        1 => s[i - 1],
        2 => 2 * s[i - 1] - s[i - 2],
        3 => 3 * s[i - 1] - 3 * s[i - 2] + s[i - 3],
        _ => 4 * s[i - 1] - 6 * s[i - 2] + 4 * s[i - 3] - s[i - 4],
      };
      final r = s[i] - predicted;
      // Zigzag: 0, -1, 1, -2, 2 ... as 0, 1, 2, 3, 4 ...
      values[i - order] = r >= 0 ? r << 1 : ((-r) << 1) - 1;
    }
    var bestBits = 1 << 62;
    var bestOrder = 0;
    var bestParams = const <int>[];
    for (var p = 0; p <= FlacEncoder._maxPartitionOrder; p++) {
      final partitions = 1 << p;
      if (n % partitions != 0 || n >> p <= order) break;
      final params = <int>[];
      var bits = 6; // coding method + partition order
      var from = 0;
      for (var k = 0; k < partitions; k++) {
        final to = (n >> p) * (k + 1) - order;
        final (param, cost) = _bestParam(values, from, to);
        params.add(param);
        bits += 4 + cost;
        from = to;
      }
      if (bits < bestBits) {
        bestBits = bits;
        bestOrder = p;
        bestParams = params;
      }
    }
    return _Residual(order, values, bestOrder, bestParams, bestBits);
  }

  final int order;
  final Int32List values;
  final int partitionOrder;
  final List<int> params;

  /// Bits to write the residual, including partition headers.
  final int bits;

  static (int, int) _bestParam(Int32List v, int from, int to) {
    final count = to - from;
    if (count <= 0) return (0, 0);
    var sum = 0;
    for (var i = from; i < to; i++) {
      sum += v[i];
    }
    var guess = 0;
    while (guess < FlacEncoder._maxRiceParam && (count << (guess + 1)) < sum) {
      guess++;
    }
    var bestParam = guess;
    var bestCost = 1 << 62;
    for (var k = guess > 0 ? guess - 1 : 0; k <= guess + 1 && k <= FlacEncoder._maxRiceParam; k++) {
      var cost = count * (k + 1);
      for (var i = from; i < to; i++) {
        cost += v[i] >> k;
      }
      if (cost < bestCost) {
        bestCost = cost;
        bestParam = k;
      }
    }
    return (bestParam, bestCost);
  }

  void writeTo(_BitWriter out) {
    out
      ..write(0, 2) // Rice, 4-bit parameters
      ..write(partitionOrder, 4);
    final n = values.length + order;
    var from = 0;
    for (var k = 0; k < params.length; k++) {
      final to = (n >> partitionOrder) * (k + 1) - order;
      final param = params[k];
      out.write(param, 4);
      for (var i = from; i < to; i++) {
        final u = values[i];
        out.writeUnary(u >> param);
        if (param > 0) out.write(u & ((1 << param) - 1), param);
      }
      from = to;
    }
  }
}

class _BitWriter {
  _BitWriter(int capacity) : _bytes = Uint8List(capacity < 64 ? 64 : capacity);

  Uint8List _bytes;
  int _length = 0;
  int _acc = 0;
  int _accBits = 0;

  Uint8List get bytes => _bytes;

  /// Whole bytes written so far (call at byte boundaries).
  int get byteLength => _length;

  void write(int value, int bits) {
    if (bits > 32) {
      write(value >> 32, bits - 32);
      write(value & 0xffffffff, 32);
      return;
    }
    _acc = (_acc << bits) | (value & ((1 << bits) - 1));
    _accBits += bits;
    while (_accBits >= 8) {
      _accBits -= 8;
      _push((_acc >> _accBits) & 0xff);
    }
    _acc &= (1 << _accBits) - 1;
  }

  /// [zeros] zero bits then a one.
  void writeUnary(int zeros) {
    while (zeros >= 32) {
      write(0, 32);
      zeros -= 32;
    }
    write(1, zeros + 1);
  }

  void alignToByte() {
    if (_accBits > 0) write(0, 8 - _accBits);
  }

  void _push(int b) {
    if (_length == _bytes.length) {
      final grown = Uint8List(_bytes.length * 2);
      grown.setRange(0, _length, _bytes);
      _bytes = grown;
    }
    _bytes[_length++] = b;
  }

  Uint8List takeBytes() {
    alignToByte();
    return Uint8List.sublistView(_bytes, 0, _length);
  }
}
