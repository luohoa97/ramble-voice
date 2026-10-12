// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// A recording being written to disk while the user speaks.
class RecordingSink {
  RecordingSink._(this.id, this.file, this._sink);

  final String id;
  final File file;
  final IOSink _sink;
  int _bytes = 0;
  bool _closed = false;

  int get bytesWritten => _bytes;

  void add(Uint8List pcm) {
    if (_closed) return;
    _sink.add(pcm);
    _bytes += pcm.length;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sink.flush();
    await _sink.close();
  }
}

/// Stores raw PCM recordings so audio is never lost: audio is streamed to
/// disk during capture and kept until the user deletes the history entry
/// (needed for "show original" and for retrying failed cleanups).
class RecordingVault {
  RecordingVault(this.directory, {this.keepLatest = 50});

  final Directory directory;

  /// Successful recordings beyond this count are pruned, oldest first.
  /// Recordings whose cleanup has not succeeded are never pruned.
  final int keepLatest;

  static const _ext = '.pcm';
  static const _pendingMarker = '.pending';

  Future<RecordingSink> begin({DateTime? now}) async {
    await directory.create(recursive: true);
    final t = (now ?? DateTime.now()).toUtc();
    final id = '${t.millisecondsSinceEpoch}';
    final file = File(p.join(directory.path, '$id$_ext'));
    await File(p.join(directory.path, '$id$_pendingMarker')).create();
    return RecordingSink._(id, file, file.openWrite());
  }

  File fileFor(String id) => File(p.join(directory.path, '$id$_ext'));

  Future<Uint8List?> read(String id) async {
    final f = fileFor(id);
    return await f.exists() ? f.readAsBytes() : null;
  }

  /// Marks cleanup as succeeded so the recording becomes prunable.
  Future<void> markProcessed(String id) async {
    final marker = File(p.join(directory.path, '$id$_pendingMarker'));
    if (await marker.exists()) await marker.delete();
    await _prune();
  }

  /// Recordings whose cleanup never succeeded (crash, error, app killed).
  Future<List<String>> pending() async {
    if (!await directory.exists()) return const [];
    final ids = <String>[];
    await for (final e in directory.list()) {
      final name = p.basename(e.path);
      if (name.endsWith(_pendingMarker)) {
        final id = name.substring(0, name.length - _pendingMarker.length);
        if (await fileFor(id).exists()) ids.add(id);
      }
    }
    ids.sort();
    return ids;
  }

  Future<void> delete(String id) async {
    for (final f in [fileFor(id), File(p.join(directory.path, '$id$_pendingMarker'))]) {
      if (await f.exists()) await f.delete();
    }
  }

  Future<void> deleteAll() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<void> _prune() async {
    final pendingIds = (await pending()).toSet();
    final done = <String>[];
    await for (final e in directory.list()) {
      final name = p.basename(e.path);
      if (name.endsWith(_ext)) {
        final id = name.substring(0, name.length - _ext.length);
        if (!pendingIds.contains(id)) done.add(id);
      }
    }
    done.sort();
    for (final id in done.take(done.length - keepLatest < 0 ? 0 : done.length - keepLatest)) {
      await delete(id);
    }
  }
}
