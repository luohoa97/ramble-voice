// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/audio/pcm.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/cleanup/cleanup_prompt.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_client.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_engine.dart';
import 'package:ramble_voice/core/style/style_profile.dart';

import '../fakes/gemini_fakes.dart';
import '../fakes/pcm_fixtures.dart';

GeminiEngine _engine(FakeGeminiServer server, {String? key = 'KEY', String? preferred, GeminiModelCache? cache}) =>
    GeminiEngine(
      apiKey: () async => key,
      client: GeminiClient(httpClient: server.client),
      preferredModel: preferred,
      cache: cache,
    );

CleanupRequest _request({CleanupMode mode = CleanupMode.clean, StyleProfile style = const StyleProfile()}) =>
    CleanupRequest(pcm: tonePcm(const Duration(milliseconds: 200)), style: style, mode: mode);


void main() {
  test('kind and audio limit', () {
    final e = _engine(FakeGeminiServer());
    expect(e.kind, EngineKind.gemini);
    expect(e.maxAudioPerRequest, const Duration(minutes: 7));
  });

  group('API key', () {
    test('missing or blank key is missingApiKey and sends nothing', () async {
      for (final key in [null, '', '   ']) {
        final server = FakeGeminiServer();
        final e = _engine(server, key: key);
        await expectLater(
          e.process(_request()),
          throwsA(isA<CleanupFailure>().having((f) => f.kind, 'kind', CleanupFailureKind.missingApiKey)),
        );
        expect(server.requests, isEmpty);
        final ready = await e.readiness();
        expect(ready, isA<EngineNotReady>().having((r) => r.reason, 'reason', CleanupFailureKind.missingApiKey));
      }
    });

    test('key is trimmed', () async {
      final server = FakeGeminiServer();
      await _engine(server, key: '  KEY \n').process(_request());
      expect(server.generateCalls.single.headers['x-goog-api-key'], 'KEY');
    });
  });

  group('model resolution', () {
    test('resolves the newest stable lite model and reports it as readiness detail', () async {
      final server = FakeGeminiServer();
      final ready = await _engine(server).readiness();
      expect(ready, isA<EngineReady>().having((r) => r.detail, 'detail', 'gemini-3.5-flash-lite'));
    });

    test('model list is fetched once for two requests', () async {
      final server = FakeGeminiServer();
      final e = _engine(server);
      await e.process(_request());
      await e.process(_request());
      expect(server.listCalls, hasLength(1));
      expect(server.generateCalls, hasLength(2));
      expect(server.generateCalls.every((r) => r.url.path.endsWith('models/gemini-3.5-flash-lite:generateContent')),
          isTrue);
    });

    test('cache expires after its ttl', () async {
      var now = DateTime(2026, 1, 1);
      final cache = GeminiModelCache(ttl: const Duration(hours: 1), clock: () => now);
      final server = FakeGeminiServer();
      final e = _engine(server, cache: cache);
      await e.process(_request());
      now = now.add(const Duration(minutes: 30));
      await e.process(_request());
      expect(server.listCalls, hasLength(1));
      now = now.add(const Duration(hours: 2));
      await e.process(_request());
      expect(server.listCalls, hasLength(2));
    });

    test('cache is per key', () async {
      final cache = GeminiModelCache();
      final server = FakeGeminiServer();
      await _engine(server, key: 'A', cache: cache).readiness();
      await _engine(server, key: 'B', cache: cache).readiness();
      expect(server.listCalls, hasLength(2));
    });

    test('preferred model is used only inside the newest generation', () async {
      final server = FakeGeminiServer();
      await _engine(server, preferred: 'gemini-3.5-flash-lite-preview-09-2026').process(_request());
      expect(server.generateCalls.single.url.path, contains('gemini-3.5-flash-lite-preview-09-2026'));

      final server2 = FakeGeminiServer();
      await _engine(server2, preferred: 'gemini-2.5-flash-lite').process(_request());
      expect(server2.generateCalls.single.url.path, contains('models/gemini-3.5-flash-lite:'));
    });

    test('no lite model listed is a server failure', () async {
      final server = FakeGeminiServer(models: [modelEntry('gemini-3.8-flash')]);
      await expectLater(
        _engine(server).process(_request()),
        throwsA(isA<CleanupFailure>().having((f) => f.kind, 'kind', CleanupFailureKind.server)),
      );
      expect(server.generateCalls, isEmpty);
    });

    test('404 on generate invalidates the cache and re-resolves', () async {
      final server = FakeGeminiServer();
      var calls = 0;
      server.onGenerate = (r, b) {
        calls++;
        if (calls == 1) {
          server.models = [modelEntry('gemini-3.6-flash-lite')];
          return errorResponse(404, 'models/gemini-3.5-flash-lite is not found', statusText: 'NOT_FOUND');
        }
        return textResponse('second try');
      };
      final e = _engine(server);
      // Prime the cache with the old list.
      await e.availableModels();
      server.models = [modelEntry('gemini-3.6-flash-lite')];

      final out = await e.process(_request());

      expect(out, 'second try');
      expect(server.listCalls, hasLength(2));
      expect(server.generateCalls, hasLength(2));
      expect(server.generateCalls.first.url.path, contains('gemini-3.5-flash-lite'));
      expect(server.generateCalls.last.url.path, contains('gemini-3.6-flash-lite'));
    });
  });

  group('thinking config', () {
    test('a rejection mentioning thinking is retried without thinkingConfig, and remembered', () async {
      final server = FakeGeminiServer();
      var calls = 0;
      server.onGenerate = (r, b) {
        calls++;
        final gen = b['generationConfig'] as Map;
        if (gen.containsKey('thinkingConfig')) {
          return errorResponse(400, 'Thinking level is not supported for this model.', statusText: 'INVALID_ARGUMENT');
        }
        return textResponse('fine');
      };
      final e = _engine(server);

      expect(await e.process(_request()), 'fine');
      expect(calls, 2);
      final bodies = server.generateCalls.map(FakeGeminiServer.bodyOf).toList();
      expect((bodies[0]['generationConfig'] as Map).containsKey('thinkingConfig'), isTrue);
      expect((bodies[1]['generationConfig'] as Map).containsKey('thinkingConfig'), isFalse);

      expect(await e.process(_request()), 'fine');
      expect(calls, 3, reason: 'later requests skip the rejected option');
    });

    test('unrelated 400s are not retried', () async {
      final server = FakeGeminiServer(onGenerate: (r, b) => errorResponse(400, 'Bad request', statusText: 'INVALID_ARGUMENT'));
      await expectLater(
        _engine(server).process(_request()),
        throwsA(isA<CleanupFailure>().having((f) => f.kind, 'kind', CleanupFailureKind.unknown)),
      );
      expect(server.generateCalls, hasLength(1));
    });
  });

  group('process', () {
    test('clean mode sends the cleanup prompt, neutral user turn and a WAV', () async {
      final server = FakeGeminiServer(onGenerate: (r, b) => textResponse('Hello.'));
      const style = StyleProfile(preset: StylePreset.professional, vocabulary: ['Ramble']);
      final req = _request(style: style);
      final out = await _engine(server).process(req);

      expect(out, 'Hello.');
      final body = FakeGeminiServer.bodyOf(server.generateCalls.single);
      final system = (((body['systemInstruction'] as Map)['parts'] as List).single as Map)['text'];
      expect(system, CleanupPrompt.build(style));
      final parts = ((body['contents'] as List).single as Map)['parts'] as List;
      expect((parts[0] as Map)['text'], CleanupPrompt.userTurn);
      final wav = base64Decode((((parts[1] as Map)['inlineData']) as Map)['data'] as String);
      expect(WavEncoder.decode(Uint8List.fromList(wav)), req.pcm);
    });

    test('verbatim mode uses the verbatim prompt', () async {
      final server = FakeGeminiServer();
      const style = StyleProfile(vocabulary: ['Ramble']);
      await _engine(server).process(_request(mode: CleanupMode.verbatim, style: style));
      final body = FakeGeminiServer.bodyOf(server.generateCalls.single);
      final system = (((body['systemInstruction'] as Map)['parts'] as List).single as Map)['text'];
      expect(system, CleanupPrompt.buildVerbatim(style));
      expect(system, isNot(CleanupPrompt.build(style)));
    });

    test('output is tidied', () async {
      final server = FakeGeminiServer(onGenerate: (r, b) => textResponse('```\nhello there\n```'));
      expect(await _engine(server).process(_request()), 'hello there');
    });

    test('failures from the API propagate with their kind', () async {
      final server = FakeGeminiServer(onGenerate: (r, b) => errorResponse(503, 'down', statusText: 'UNAVAILABLE'));
      await expectLater(
        _engine(server).process(_request()),
        throwsA(isA<CleanupFailure>().having((f) => f.kind, 'kind', CleanupFailureKind.server)),
      );
    });
  });

  group('testKey', () {
    test('sends a 0.5 s silent WAV and returns the model id', () async {
      final server = FakeGeminiServer();
      final id = await _engine(server).testKey();
      expect(id, 'gemini-3.5-flash-lite');
      final body = FakeGeminiServer.bodyOf(server.generateCalls.single);
      final parts = ((body['contents'] as List).single as Map)['parts'] as List;
      final wav = Uint8List.fromList(base64Decode((((parts[1] as Map)['inlineData']) as Map)['data'] as String));
      expect(wav.length, 44 + Pcm.bytesFor(const Duration(milliseconds: 500)));
      expect(WavEncoder.decode(wav).every((b) => b == 0), isTrue);
    });

    test('refreshes the model list even when cached', () async {
      final server = FakeGeminiServer();
      final e = _engine(server);
      await e.availableModels();
      await e.testKey();
      expect(server.listCalls, hasLength(2));
    });

    test('an invalid key surfaces as invalidApiKey', () async {
      final server = FakeGeminiServer(
        onGenerate: (r, b) => errorResponse(400, 'API key not valid', details: [
          {'@type': 'type.googleapis.com/google.rpc.ErrorInfo', 'reason': 'API_KEY_INVALID'},
        ]),
      );
      await expectLater(
        _engine(server).testKey(),
        throwsA(isA<CleanupFailure>().having((f) => f.kind, 'kind', CleanupFailureKind.invalidApiKey)),
      );
    });
  });
}
