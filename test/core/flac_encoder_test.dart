// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/audio/flac_encoder.dart';
import 'package:ramble_voice/core/audio/pcm.dart';

import '../fakes/pcm_fixtures.dart';

/// The samples of a fixture WAV (44-byte header).
Uint8List _fixture(String name) =>
    Uint8List.sublistView(File('test/fixtures/injection/audio/$name').readAsBytesSync(), WavEncoder.headerLength);

void main() {
  test('speech compresses losslessly to well under the WAV size', () {
    final pcm = _fixture('poem.wav');
    final flac = FlacEncoder.encode(pcm);
    expect(String.fromCharCodes(flac.take(4)), 'fLaC');
    expect(flac.length, lessThan(pcm.length * 0.8));
  });

  // Checked bit-exact against the reference `flac -d` decoder when written.
  test('silence, tones, a partial last block and extremes encode', () {
    final pcm = concatBytes([
      silencePcm(const Duration(milliseconds: 700)),
      tonePcm(const Duration(milliseconds: 1300)),
      Uint8List.fromList([for (var i = 0; i < 2000; i++) ...(i.isEven ? [0xff, 0x7f] : [0x00, 0x80])]),
      Uint8List(Pcm.bytesFor(const Duration(milliseconds: 37)) + 6),
    ]);
    final flac = FlacEncoder.encode(pcm);
    expect(flac.length, lessThan(pcm.length));
  });

  test('empty audio is a valid empty stream', () {
    final flac = FlacEncoder.encode(Uint8List(0));
    expect(flac.length, 42);
  });
}
