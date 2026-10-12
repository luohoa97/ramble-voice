// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../core/models/model_catalog.dart';
import '../../core/models/model_downloader.dart';
import '../../core/models/model_downloads.dart';

/// Model downloads over the Kotlin `ModelDownloadService` (channel
/// `ramble/download`, live updates on `ramble/download/progress`). The service
/// is a foreground service with a lock-screen Live Update, so the transfer
/// keeps running when the app is backgrounded or swiped away. It resumes the
/// `.part` file with HTTP Range, verifies SHA-256 and renames the file only if
/// the hash matches, so a final file on disk is always a verified one.
class AndroidModelDownloads implements ModelDownloads {
  AndroidModelDownloads({
    required this.directory,
    MethodChannel? channel,
    Stream<dynamic>? events,
    Future<void> Function()? requestNotifications,
  })  : _channel = channel ?? const MethodChannel('ramble/download'),
        // ignore: prefer_initializing_formals
        _events = events,
        _requestNotifications = requestNotifications ?? _defaultRequestNotifications;

  /// Resolves `<externalFilesDir>/models` from the platform side.
  static Future<AndroidModelDownloads> create({MethodChannel? channel}) async {
    final ch = channel ?? const MethodChannel('ramble/download');
    final path = await ch.invokeMethod<String>('modelsDir');
    return AndroidModelDownloads(directory: Directory(path!), channel: ch);
  }

  static Future<void> _defaultRequestNotifications() async {
    // Without it the download still runs, but its progress is not shown.
    await Permission.notification.request();
  }

  final Directory directory;
  final MethodChannel _channel;
  final Future<void> Function() _requestNotifications;
  Stream<dynamic>? _events;
  StreamSubscription<dynamic>? _eventSub;

  final _controllers = <String, StreamController<DownloadStatus>>{};
  final _status = <String, DownloadStatus>{};
  final _known = <String, GemmaVariant>{};

  @override
  bool get supportsPause => true;

  @override
  File finalFile(GemmaVariant v) => File(p.join(directory.path, v.file));
  File partFile(GemmaVariant v) => File(p.join(directory.path, '${v.file}.part'));

  @override
  Stream<DownloadStatus> watch(GemmaVariant v) {
    _attach(v);
    return _controllers.putIfAbsent(v.id, () => StreamController<DownloadStatus>.broadcast()).stream;
  }

  @override
  DownloadStatus statusOf(GemmaVariant v) => _status[v.id] ?? const NotDownloaded();

  @override
  bool isActive(GemmaVariant v) => switch (statusOf(v)) {
        Downloading() || Verifying() => true,
        _ => false,
      };

  void _set(GemmaVariant v, DownloadStatus s) {
    _status[v.id] = s;
    _controllers[v.id]?.add(s);
  }

  /// Registers [v] for event routing and subscribes to the service's updates.
  void _attach(GemmaVariant v) {
    _known[v.file] = v;
    if (_eventSub != null) return;
    final events = _events ??= const EventChannel('ramble/download/progress').receiveBroadcastStream();
    _eventSub = events.listen(_onEvent, onError: (Object _) {});
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final v = _known[event['fileName']];
    if (v == null) return;
    final s = _fromReport(v, event);
    if (s != null) _set(v, s);
  }

  DownloadStatus? _fromReport(GemmaVariant v, Map<dynamic, dynamic> r) {
    final bytes = (r['bytes'] as num?)?.toInt() ?? 0;
    final reported = (r['total'] as num?)?.toInt() ?? 0;
    final total = reported > 0 ? reported : v.sizeBytes;
    return switch (r['state']) {
      'running' || 'retrying' => Downloading(bytes, total),
      'paused' => Paused(bytes, total),
      'verifying' => const Verifying(),
      'done' => Downloaded(finalFile(v).path),
      'failed' => DownloadFailed(r['error'] as String? ?? 'The download failed.', received: bytes, total: v.sizeBytes),
      'idle' => const NotDownloaded(),
      _ => null,
    };
  }

  @override
  Future<DownloadStatus> refresh(GemmaVariant v) async {
    _attach(v);
    final done = finalFile(v);
    if (await done.exists() && await done.length() == v.sizeBytes) {
      _set(v, Downloaded(done.path));
      return statusOf(v);
    }
    Map<dynamic, dynamic>? report;
    try {
      report = await _channel.invokeMapMethod<dynamic, dynamic>('status', {'fileName': v.file});
    } on PlatformException {
      report = null;
    }
    var s = report == null ? null : _fromReport(v, report);
    // The service only ever renames a verified file, so "done" without the
    // right-sized file on disk means it is gone.
    if (s is Downloaded) s = null;
    if (s == null || s is NotDownloaded) {
      final part = partFile(v);
      s = await part.exists() ? Paused(await part.length(), v.sizeBytes) : const NotDownloaded();
    }
    _set(v, s);
    return s;
  }

  /// Starts or resumes. The service keeps going after this returns; progress
  /// arrives through [watch].
  @override
  Future<DownloadStatus> start(GemmaVariant v) async {
    _attach(v);
    if (isActive(v)) return statusOf(v);
    await directory.create(recursive: true);
    final part = partFile(v);
    var have = await part.exists() ? await part.length() : 0;
    if (have > v.sizeBytes) {
      await part.delete();
      have = 0;
    }
    await _requestNotifications();
    _set(v, Downloading(have, v.sizeBytes));
    try {
      await _channel.invokeMethod<void>('start', {
        'url': v.downloadUrl.toString(),
        'fileName': v.file,
        'sha256': v.sha256,
        'sizeBytes': v.sizeBytes,
        'title': 'Downloading ${v.label}',
      });
    } on PlatformException catch (e) {
      _set(v, DownloadFailed(e.message ?? 'Could not start the download.', received: have, total: v.sizeBytes));
    }
    return statusOf(v);
  }

  /// Stops the transfer and keeps the partial file for [start] to resume.
  @override
  Future<void> pause(GemmaVariant v) async {
    _attach(v);
    await _invoke('pause', v);
    final part = partFile(v);
    _set(v, Paused(await part.exists() ? await part.length() : 0, v.sizeBytes));
  }

  @override
  Future<void> delete(GemmaVariant v) async {
    _attach(v);
    await _invoke('cancel', v);
    for (final f in [finalFile(v), partFile(v)]) {
      if (await f.exists()) await f.delete();
    }
    _set(v, const NotDownloaded());
  }

  Future<void> _invoke(String method, GemmaVariant v) async {
    try {
      await _channel.invokeMethod<void>(method, {'fileName': v.file});
    } on PlatformException {
      // Nothing running to stop.
    }
  }

  void dispose() {
    _eventSub?.cancel();
    _eventSub = null;
    for (final c in _controllers.values) {
      c.close();
    }
  }
}
