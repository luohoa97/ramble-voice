// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'model_catalog.dart';
import 'model_downloads.dart';

sealed class DownloadStatus {
  const DownloadStatus();
}

class NotDownloaded extends DownloadStatus {
  const NotDownloaded();
}

class Downloading extends DownloadStatus {
  const Downloading(this.received, this.total);
  final int received;
  final int total;
  double get fraction => total == 0 ? 0 : received / total;
}

class Paused extends DownloadStatus {
  const Paused(this.received, this.total);
  final int received;
  final int total;
  double get fraction => total == 0 ? 0 : received / total;
}

class Verifying extends DownloadStatus {
  const Verifying();
}

class Downloaded extends DownloadStatus {
  const Downloaded(this.path);
  final String path;
}

class DownloadFailed extends DownloadStatus {
  const DownloadFailed(this.message, {this.received = 0, this.total = 0});
  final String message;
  final int received;
  final int total;
}

/// Resumable model download with pause/resume (HTTP Range), SHA-256
/// verification against the hash Hugging Face publishes, and delete.
class ModelDownloader implements ModelDownloads {
  ModelDownloader({
    required this.directory,
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  /// Where models live, e.g. `<app support>/models`.
  final Directory directory;

  @override
  bool get supportsPause => true;
  final http.Client Function() _clientFactory;

  final _controllers = <String, StreamController<DownloadStatus>>{};
  final _status = <String, DownloadStatus>{};
  final _active = <String, http.Client>{};

  @override
  File finalFile(GemmaVariant v) => File(p.join(directory.path, v.file));
  File partFile(GemmaVariant v) =>
      File(p.join(directory.path, '${v.file}.part'));

  @override
  Stream<DownloadStatus> watch(GemmaVariant v) {
    final c = _controllers.putIfAbsent(
      v.id,
      () => StreamController<DownloadStatus>.broadcast(),
    );
    return c.stream;
  }

  @override
  DownloadStatus statusOf(GemmaVariant v) =>
      _status[v.id] ?? const NotDownloaded();

  void _set(GemmaVariant v, DownloadStatus s) {
    _status[v.id] = s;
    _controllers[v.id]?.add(s);
  }

  /// Reads on-disk state (call at startup).
  @override
  Future<DownloadStatus> refresh(GemmaVariant v) async {
    if (_active.containsKey(v.id)) return statusOf(v);
    final done = finalFile(v);
    if (await done.exists() && await done.length() == v.sizeBytes) {
      _set(v, Downloaded(done.path));
    } else if (await partFile(v).exists()) {
      _set(v, Paused(await partFile(v).length(), v.sizeBytes));
    } else {
      _set(v, const NotDownloaded());
    }
    return statusOf(v);
  }

  @override
  bool isActive(GemmaVariant v) => _active.containsKey(v.id);

  /// Starts or resumes. Completes when the download ends (done, paused or
  /// failed); progress is reported through [watch].
  @override
  Future<DownloadStatus> start(GemmaVariant v) async {
    if (_active.containsKey(v.id)) return statusOf(v);
    await directory.create(recursive: true);
    final part = partFile(v);
    var received = await part.exists() ? await part.length() : 0;
    if (received > v.sizeBytes) {
      await part.delete();
      received = 0;
    }
    final client = _clientFactory();
    _active[v.id] = client;
    IOSink? sink;
    try {
      if (received < v.sizeBytes) {
        final req = http.Request('GET', v.downloadUrl);
        if (received > 0) req.headers['Range'] = 'bytes=$received-';
        final res = await client.send(req);
        if (res.statusCode == 200 && received > 0) {
          // Server ignored Range: start over.
          received = 0;
          sink = part.openWrite();
        } else if (res.statusCode == 200 || res.statusCode == 206) {
          sink = part.openWrite(
            mode: received > 0 ? FileMode.append : FileMode.write,
          );
        } else if (res.statusCode == 416) {
          // Already complete on disk.
          sink = null;
        } else {
          throw HttpException(
            'Download failed (HTTP ${res.statusCode})',
            uri: v.downloadUrl,
          );
        }
        if (sink != null) {
          _set(v, Downloading(received, v.sizeBytes));
          var lastReport = DateTime.now();
          await for (final block in res.stream) {
            sink.add(block);
            received += block.length;
            final now = DateTime.now();
            if (now.difference(lastReport) >
                const Duration(milliseconds: 150)) {
              lastReport = now;
              _set(v, Downloading(received, v.sizeBytes));
            }
          }
          await sink.flush();
          await sink.close();
          sink = null;
        }
      }
      if (!_active.containsKey(v.id)) return statusOf(v); // paused meanwhile
      _set(v, const Verifying());
      if (await part.length() != v.sizeBytes) {
        throw const FileSystemException(
          'Download ended early. Resume to finish it.',
        );
      }
      final digest = await sha256.bind(part.openRead()).first;
      if (digest.toString() != v.sha256) {
        await part.delete();
        throw const FileSystemException(
          'The downloaded file failed its checksum and was removed.',
        );
      }
      final done = await part.rename(finalFile(v).path);
      _set(v, Downloaded(done.path));
    } on http.ClientException catch (e) {
      if (_active.containsKey(v.id)) {
        _set(
          v,
          DownloadFailed(
            'Network error: ${e.message}',
            received: received,
            total: v.sizeBytes,
          ),
        );
      }
    } on Exception catch (e) {
      if (_active.containsKey(v.id)) {
        final msg = e is FileSystemException
            ? (e.osError?.errorCode == 28
                  ? 'Not enough storage space.'
                  : e.message)
            : e.toString();
        _set(v, DownloadFailed(msg, received: received, total: v.sizeBytes));
      }
    } finally {
      await sink?.close();
      _active.remove(v.id)?.close();
    }
    return statusOf(v);
  }

  /// Stops the transfer and keeps the partial file for [start] to resume.
  @override
  Future<void> pause(GemmaVariant v) async {
    final client = _active.remove(v.id);
    client?.close();
    final part = partFile(v);
    _set(v, Paused(await part.exists() ? await part.length() : 0, v.sizeBytes));
  }

  @override
  Future<void> delete(GemmaVariant v) async {
    await pause(v);
    for (final f in [finalFile(v), partFile(v)]) {
      if (await f.exists()) await f.delete();
    }
    _set(v, const NotDownloaded());
  }
}
