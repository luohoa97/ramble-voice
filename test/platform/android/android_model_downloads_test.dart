// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ramble_voice/core/models/model_catalog.dart';
import 'package:ramble_voice/core/models/model_downloader.dart';
import 'package:ramble_voice/platform/android/android_model_downloads.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ramble/download');
  const variant = GemmaVariant(
    id: 'tiny',
    label: 'Tiny',
    repo: 'test/tiny',
    file: 'tiny.litertlm',
    sizeBytes: 100,
    sha256: 'abc',
    recommendedRamGb: 1,
    summary: '',
  );

  late Directory dir;
  late List<MethodCall> calls;
  late Map<String, Object?> statusReply;
  late StreamController<dynamic> events;
  late AndroidModelDownloads downloads;
  var notificationRequests = 0;

  AndroidModelDownloads make() => AndroidModelDownloads(
    directory: dir,
    channel: channel,
    events: events.stream,
    requestNotifications: () async => notificationRequests++,
  );

  Map<String, Object?> event(String state, {int bytes = 0, String? error}) => {
    'fileName': 'tiny.litertlm',
    'state': state,
    'bytes': bytes,
    'total': 100,
    'error': error,
  };

  File part() => File(p.join(dir.path, 'tiny.litertlm.part'));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ramble_dl_');
    calls = [];
    notificationRequests = 0;
    statusReply = {
      'fileName': 'tiny.litertlm',
      'state': 'idle',
      'bytes': 0,
      'total': 0,
    };
    events = StreamController<dynamic>.broadcast();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'status' => statusReply,
            'modelsDir' => dir.path,
            _ => null,
          };
        });
    downloads = make();
  });

  tearDown(() async {
    downloads.dispose();
    await events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await dir.delete(recursive: true);
  });

  List<MethodCall> named(String m) =>
      calls.where((c) => c.method == m).toList();

  test('create resolves the models directory and pause is supported', () async {
    final d = await AndroidModelDownloads.create(channel: channel);
    expect(d.directory.path, dir.path);
    expect(d.supportsPause, isTrue);
  });

  test('start asks for notifications, then starts the service with the expected hash', () async {
    final s = await downloads.start(variant);
    expect(s, isA<Downloading>());
    expect(notificationRequests, 1);
    expect(named('start').single.arguments, {
      'url': variant.downloadUrl.toString(),
      'fileName': 'tiny.litertlm',
      'sha256': 'abc',
      'sizeBytes': 100,
      'title': 'Downloading Tiny',
    });
    await downloads.start(variant);
    expect(named('start'), hasLength(1));
  });

  test('start resumes from the bytes already on disk', () async {
    part().writeAsBytesSync(List.filled(40, 1));
    final s = await downloads.start(variant);
    expect((s as Downloading).received, 40);
  });

  test('progress events update the status', () async {
    final seen = downloads
        .watch(variant)
        .firstWhere((s) => s is Downloading && s.received == 30);
    events.add(event('running', bytes: 30));
    expect((await seen as Downloading).total, 100);
    expect(downloads.isActive(variant), isTrue);
  });

  test('verifying then done reports Downloaded', () async {
    final done = downloads.watch(variant).firstWhere((s) => s is Downloaded);
    events.add(event('verifying', bytes: 100));
    await pumpEventQueue();
    expect(downloads.statusOf(variant), isA<Verifying>());
    events.add(event('done', bytes: 100));
    expect((await done as Downloaded).path, downloads.finalFile(variant).path);
  });

  test('a checksum failure surfaces the service error', () async {
    final failed = downloads
        .watch(variant)
        .firstWhere((s) => s is DownloadFailed);
    events.add(
      event(
        'failed',
        error: 'The downloaded file failed its checksum and was removed.',
      ),
    );
    expect((await failed as DownloadFailed).message, contains('checksum'));
  });

  test('refresh re-attaches to a running service', () async {
    statusReply = event('running', bytes: 55);
    final s = await downloads.refresh(variant);
    expect((s as Downloading).received, 55);
    expect(named('start'), isEmpty);
  });

  test(
    'refresh picks up a model that finished while the app was closed',
    () async {
      File(p.join(dir.path, 'tiny.litertlm'))
          .writeAsBytesSync(List.filled(100, 1));
      expect(await downloads.refresh(variant), isA<Downloaded>());
    },
  );

  test('refresh with only a part file is Paused', () async {
    part().writeAsBytesSync(List.filled(20, 1));
    final s = await downloads.refresh(variant);
    expect((s as Paused).received, 20);
  });

  test('refresh with nothing is NotDownloaded', () async {
    expect(await downloads.refresh(variant), isA<NotDownloaded>());
  });

  test('pause keeps the partial file', () async {
    await downloads.start(variant);
    part().writeAsBytesSync(List.filled(25, 1));
    await downloads.pause(variant);
    expect(named('pause').single.arguments, {'fileName': 'tiny.litertlm'});
    expect((downloads.statusOf(variant) as Paused).received, 25);
    expect(part().existsSync(), isTrue);
  });

  test('cancel stops the service and deletes the partial file', () async {
    await downloads.start(variant);
    part().writeAsBytesSync(List.filled(25, 1));
    await downloads.delete(variant);
    expect(named('cancel').single.arguments, {'fileName': 'tiny.litertlm'});
    expect(downloads.statusOf(variant), isA<NotDownloaded>());
    expect(part().existsSync(), isFalse);
  });
}
