// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ramble_voice/core/models/model_catalog.dart';
import 'package:ramble_voice/core/models/model_downloader.dart';

import '../fakes/temp_dirs.dart';

final Uint8List _bytes = Uint8List.fromList([for (var i = 0; i < 3000; i++) (i * 7 + 3) % 256]);

GemmaVariant _variant({Uint8List? content, String? sha}) {
  final data = content ?? _bytes;
  return GemmaVariant(
    id: 'tiny',
    label: 'Tiny',
    repo: 'test/tiny',
    file: 'tiny.litertlm',
    sizeBytes: data.length,
    sha256: sha ?? sha256.convert(data).toString(),
    recommendedRamGb: 1,
    summary: 'test',
  );
}

/// Chunks [data] into pieces of [size] bytes.
Stream<List<int>> _chunks(List<int> data, [int size = 700]) async* {
  for (var i = 0; i < data.length; i += size) {
    yield data.sublist(i, i + size > data.length ? data.length : i + size);
    await Future<void>.delayed(Duration.zero);
  }
}

class _Server {
  _Server(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest request) handler;
  final List<http.BaseRequest> requests = [];

  MockClient get client => MockClient.streaming((request, body) async {
        requests.add(request);
        return handler(request);
      });

  /// Honours Range, like Hugging Face.
  static _Server ranged(Uint8List data) => _Server((request) async {
        final range = request.headers['Range'];
        if (range == null) {
          return http.StreamedResponse(_chunks(data), 200, contentLength: data.length);
        }
        final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        return http.StreamedResponse(_chunks(data.sublist(from)), 206, contentLength: data.length - from);
      });
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory('${(await makeTempDir()).path}/models');
  });

  ModelDownloader downloader(_Server server) => ModelDownloader(directory: dir, clientFactory: () => server.client);

  test('fresh download reports progress, verifies and renames', () async {
    final v = _variant();
    final server = _Server.ranged(_bytes);
    final d = downloader(server);
    final seen = <DownloadStatus>[];
    d.watch(v).listen(seen.add);

    final result = await d.start(v);
    await Future<void>.delayed(Duration.zero);

    expect(result, isA<Downloaded>());
    expect(await d.finalFile(v).readAsBytes(), _bytes);
    expect(await d.partFile(v).exists(), isFalse);
    expect(seen.first, isA<Downloading>().having((s) => s.total, 'total', _bytes.length));
    final verifyAt = seen.indexWhere((s) => s is Verifying);
    expect(verifyAt, greaterThan(0));
    expect(seen.last, isA<Downloaded>().having((s) => s.path, 'path', d.finalFile(v).path));
    expect(seen.take(verifyAt).every((s) => s is Downloading), isTrue);
    expect(server.requests.single.headers.containsKey('Range'), isFalse);
    expect(server.requests.single.url, v.downloadUrl);
    expect(d.statusOf(v), isA<Downloaded>());
    expect(d.isActive(v), isFalse);
  });

  test('checksum mismatch deletes the part and fails', () async {
    final v = _variant(sha: 'f' * 64);
    final d = downloader(_Server.ranged(_bytes));
    final result = await d.start(v);
    expect(result, isA<DownloadFailed>().having((s) => s.message, 'message', contains('checksum')));
    expect(await d.partFile(v).exists(), isFalse);
    expect(await d.finalFile(v).exists(), isFalse);
  });

  test('resume sends Range and appends', () async {
    final v = _variant();
    await dir.create(recursive: true);
    await File('${dir.path}/${v.file}.part').writeAsBytes(_bytes.sublist(0, 1200));
    final server = _Server.ranged(_bytes);
    final d = downloader(server);

    final result = await d.start(v);

    expect(server.requests.single.headers['Range'], 'bytes=1200-');
    expect(result, isA<Downloaded>());
    expect(await d.finalFile(v).readAsBytes(), _bytes);
  });

  test('a server that ignores Range (200) restarts from zero', () async {
    final v = _variant();
    await dir.create(recursive: true);
    await File('${dir.path}/${v.file}.part').writeAsBytes(_bytes.sublist(0, 1200));
    final server = _Server((r) async => http.StreamedResponse(_chunks(_bytes), 200, contentLength: _bytes.length));
    final d = downloader(server);

    final result = await d.start(v);

    expect(server.requests.single.headers['Range'], 'bytes=1200-');
    expect(result, isA<Downloaded>());
    expect(await d.finalFile(v).readAsBytes(), _bytes, reason: 'must not be 1200 bytes of duplicate prefix');
  });

  test('a complete part file is verified without a request', () async {
    final v = _variant();
    await dir.create(recursive: true);
    await File('${dir.path}/${v.file}.part').writeAsBytes(_bytes);
    final server = _Server.ranged(_bytes);
    final result = await downloader(server).start(v);
    expect(result, isA<Downloaded>());
    expect(server.requests, isEmpty);
  });

  test('an oversized part file is discarded and the download restarts', () async {
    final v = _variant();
    await dir.create(recursive: true);
    await File('${dir.path}/${v.file}.part').writeAsBytes([..._bytes, 1, 2, 3]);
    final server = _Server.ranged(_bytes);
    final d = downloader(server);
    expect(await d.start(v), isA<Downloaded>());
    expect(server.requests.single.headers.containsKey('Range'), isFalse);
    expect(await d.finalFile(v).readAsBytes(), _bytes);
  });

  test('HTTP errors fail with the status', () async {
    final v = _variant();
    final d = downloader(_Server((r) async => http.StreamedResponse(const Stream.empty(), 404)));
    final result = await d.start(v);
    expect(result, isA<DownloadFailed>().having((s) => s.message, 'message', contains('404')));
  });

  test('a network error keeps the part file for resume', () async {
    final v = _variant();
    final server = _Server((r) async {
      Stream<List<int>> broken() async* {
        yield _bytes.sublist(0, 900);
        await Future<void>.delayed(Duration.zero);
        throw http.ClientException('connection reset');
      }

      return http.StreamedResponse(broken(), 200, contentLength: _bytes.length);
    });
    final d = downloader(server);
    final result = await d.start(v);
    expect(result, isA<DownloadFailed>()
        .having((s) => s.message, 'message', contains('Network error'))
        .having((s) => s.received, 'received', 900));
    expect(await d.partFile(v).length(), 900);

    // Resume works afterwards.
    final ok = _Server.ranged(_bytes);
    final again = ModelDownloader(directory: dir, clientFactory: () => ok.client);
    expect(await again.start(v), isA<Downloaded>());
    expect(ok.requests.single.headers['Range'], 'bytes=900-');
  });

  test('a stream that ends early is a failure that can be resumed', () async {
    final v = _variant();
    final d = downloader(_Server((r) async => http.StreamedResponse(_chunks(_bytes.sublist(0, 2000)), 200)));
    final result = await d.start(v);
    expect(result, isA<DownloadFailed>().having((s) => s.message, 'message', contains('ended early')));
    expect(await d.partFile(v).length(), 2000);
  });

  test('pause keeps the part file and reports Paused', () async {
    final v = _variant();
    final body = StreamController<List<int>>();
    final server = _Server((r) async => http.StreamedResponse(body.stream, 200, contentLength: _bytes.length));
    final d = downloader(server);

    final running = d.start(v);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    body.add(_bytes.sublist(0, 1000));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(d.isActive(v), isTrue);

    await d.pause(v);
    // A real client aborts the transfer when closed.
    body.addError(http.ClientException('closed'));
    await body.close();
    final result = await running;

    expect(result, isA<Paused>());
    expect(d.statusOf(v), isA<Paused>().having((s) => s.received, 'received', 1000));
    expect(d.isActive(v), isFalse);
    expect(await d.partFile(v).length(), 1000);
    expect(await d.finalFile(v).exists(), isFalse);

    // Resuming from the pause finishes the file.
    final ok = _Server.ranged(_bytes);
    final again = ModelDownloader(directory: dir, clientFactory: () => ok.client);
    expect(await again.start(v), isA<Downloaded>());
    expect(await again.finalFile(v).readAsBytes(), _bytes);
  });

  test('a second start while active is ignored', () async {
    final v = _variant();
    final body = StreamController<List<int>>();
    final server = _Server((r) async => http.StreamedResponse(body.stream, 200));
    final d = downloader(server);
    final first = d.start(v);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final second = await d.start(v);
    expect(second, isA<Downloading>());
    expect(server.requests, hasLength(1));
    body.add(_bytes);
    await body.close();
    expect(await first, isA<Downloaded>());
  });

  test('delete removes the final and part files', () async {
    final v = _variant();
    final d = downloader(_Server.ranged(_bytes));
    await d.start(v);
    await File('${dir.path}/${v.file}.part').writeAsBytes([1]);
    await d.delete(v);
    expect(await d.finalFile(v).exists(), isFalse);
    expect(await d.partFile(v).exists(), isFalse);
    expect(d.statusOf(v), isA<NotDownloaded>());
  });

  group('refresh', () {
    test('nothing on disk', () async {
      final d = downloader(_Server.ranged(_bytes));
      expect(await d.refresh(_variant()), isA<NotDownloaded>());
    });

    test('a part file is Paused with its size', () async {
      final v = _variant();
      await dir.create(recursive: true);
      await File('${dir.path}/${v.file}.part').writeAsBytes(_bytes.sublist(0, 321));
      final s = await downloader(_Server.ranged(_bytes)).refresh(v);
      expect(s, isA<Paused>().having((p) => p.received, 'received', 321).having((p) => p.fraction, 'fraction', closeTo(0.107, 0.001)));
    });

    test('a final file of the right size is Downloaded', () async {
      final v = _variant();
      await dir.create(recursive: true);
      await File('${dir.path}/${v.file}').writeAsBytes(_bytes);
      expect(await downloader(_Server.ranged(_bytes)).refresh(v), isA<Downloaded>());
    });

    test('a final file of the wrong size is not Downloaded', () async {
      final v = _variant();
      await dir.create(recursive: true);
      await File('${dir.path}/${v.file}').writeAsBytes(_bytes.sublist(0, 10));
      expect(await downloader(_Server.ranged(_bytes)).refresh(v), isA<NotDownloaded>());
    });
  });

  group('ModelCatalog', () {
    test('variants are well formed', () {
      for (final v in ModelCatalog.all) {
        expect(v.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(v.downloadUrl.toString(), startsWith('https://huggingface.co/'));
        expect(v.downloadUrl.path, endsWith(v.file));
        expect(v.sizeBytes, greaterThan(1 << 30));
      }
      expect(ModelCatalog.byId('gemma-4-e2b'), ModelCatalog.e2b);
      expect(ModelCatalog.byId('nope'), isNull);
      expect(ModelCatalog.byId(null), isNull);
      expect(ModelCatalog.defaultVariant, ModelCatalog.e4b);
      expect(ModelCatalog.e4b.sizeLabel, '3.7 GB');
      expect(ModelCatalog.maxAudioPerRequest, lessThan(const Duration(seconds: 30)));
    });
  });
}
