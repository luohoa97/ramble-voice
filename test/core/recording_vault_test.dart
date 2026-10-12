// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/dictation/recording_vault.dart';

import '../fakes/temp_dirs.dart';

DateTime _t(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

Future<String> _record(RecordingVault v, int ms, List<int> bytes) async {
  final sink = await v.begin(now: _t(ms));
  sink.add(Uint8List.fromList(bytes));
  await sink.close();
  return sink.id;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory('${(await makeTempDir()).path}/vault');
  });

  test('begin creates the directory, a pending marker and an id from the time', () async {
    final vault = RecordingVault(dir);
    final sink = await vault.begin(now: _t(1234));
    expect(sink.id, '1234');
    expect(await dir.exists(), isTrue);
    expect(await File('${dir.path}/1234.pending').exists(), isTrue);
    await sink.close();
  });

  test('add, close and read back', () async {
    final vault = RecordingVault(dir);
    final sink = await vault.begin(now: _t(1));
    sink.add(Uint8List.fromList([1, 2, 3, 4]));
    sink.add(Uint8List.fromList([5, 6]));
    expect(sink.bytesWritten, 6);
    await sink.close();
    expect(await vault.read(sink.id), [1, 2, 3, 4, 5, 6]);
    expect(vault.fileFor(sink.id).path, '${dir.path}/1.pcm');
  });

  test('writes after close are ignored and close is idempotent', () async {
    final vault = RecordingVault(dir);
    final sink = await vault.begin(now: _t(1));
    sink.add(Uint8List.fromList([1, 2]));
    await sink.close();
    sink.add(Uint8List.fromList([9, 9]));
    await sink.close();
    expect(sink.bytesWritten, 2);
    expect(await vault.read(sink.id), [1, 2]);
  });

  test('read of an unknown id is null', () async {
    expect(await RecordingVault(dir).read('nope'), isNull);
  });

  test('pending lists unprocessed recordings sorted, and survives a new vault instance', () async {
    final vault = RecordingVault(dir);
    final b = await _record(vault, 2000, [1, 2]);
    final a = await _record(vault, 1000, [3, 4]);
    expect(await vault.pending(), [a, b]);
    expect(await RecordingVault(dir).pending(), [a, b]);
  });

  test('pending is empty before anything exists', () async {
    expect(await RecordingVault(dir).pending(), isEmpty);
  });

  test('a marker without audio is not pending', () async {
    final vault = RecordingVault(dir);
    await dir.create(recursive: true);
    await File('${dir.path}/7.pending').create();
    expect(await vault.pending(), isEmpty);
  });

  test('markProcessed clears the marker but keeps the audio', () async {
    final vault = RecordingVault(dir);
    final id = await _record(vault, 1, [1, 2]);
    await vault.markProcessed(id);
    expect(await vault.pending(), isEmpty);
    expect(await vault.read(id), [1, 2]);
    await vault.markProcessed(id); // idempotent
  });

  test('prune keeps the latest N processed recordings, never pending ones', () async {
    final vault = RecordingVault(dir, keepLatest: 2);
    final pendingOld = await _record(vault, 1, [0, 0]); // oldest, never processed
    final ids = [for (var i = 2; i <= 5; i++) await _record(vault, i, [i, 0])];
    for (final id in ids) {
      await vault.markProcessed(id);
    }
    expect(await vault.read(ids[0]), isNull);
    expect(await vault.read(ids[1]), isNull);
    expect(await vault.read(ids[2]), isNotNull);
    expect(await vault.read(ids[3]), isNotNull);
    expect(await vault.read(pendingOld), isNotNull, reason: 'pending audio must survive pruning');
    expect(await vault.pending(), [pendingOld]);
  });

  test('prune does nothing under the limit', () async {
    final vault = RecordingVault(dir, keepLatest: 5);
    final ids = [for (var i = 1; i <= 3; i++) await _record(vault, i, [i, 0])];
    for (final id in ids) {
      await vault.markProcessed(id);
    }
    for (final id in ids) {
      expect(await vault.read(id), isNotNull);
    }
  });

  test('delete removes audio and marker; unknown ids are fine', () async {
    final vault = RecordingVault(dir);
    final id = await _record(vault, 1, [1, 2]);
    await vault.delete(id);
    expect(await vault.read(id), isNull);
    expect(await vault.pending(), isEmpty);
    expect(await File('${dir.path}/$id.pending').exists(), isFalse);
    await vault.delete('missing');
  });

  test('deleteAll removes everything and the vault is usable again', () async {
    final vault = RecordingVault(dir);
    await _record(vault, 1, [1, 2]);
    await _record(vault, 2, [1, 2]);
    await vault.deleteAll();
    expect(await dir.exists(), isFalse);
    expect(await vault.pending(), isEmpty);
    await vault.deleteAll();
    final id = await _record(vault, 3, [9, 9]);
    expect(await vault.read(id), [9, 9]);
  });
}
