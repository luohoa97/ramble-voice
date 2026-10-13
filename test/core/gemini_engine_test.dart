// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ramble_voice/core/audio/pcm.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/cleanup/cleanup_prompt.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_client.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_engine.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_models.dart';
import 'package:ramble_voice/core/style/style_profile.dart';

import '../fakes/gemini_fakes.dart';
import '../fakes/pcm_fixtures.dart';

GeminiEngine _engine(FakeGeminiServer server, {String? key = 'KEY', String? preferred, GeminiModelCache? cache}) =>
    GeminiEngine(
      apiKey: () async => key,
      client: GeminiClient(httpClient: server.client),
      preferredModel: preferred,
      cache: cache,
      overloadBackoff: Duration.zero,
    );

CleanupRequest _request({CleanupMode mode = CleanupMode.clean, StyleProfile style = const StyleProfile()}) =>
    CleanupRequest(pcm: tonePcm(const Duration(milliseconds: 200)), style: style, mode: mode);


void main() {
  editModeTests();
  fallbackChainTests();
  healthProbeTests();
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
      expect(ready, isA<EngineReady>().having((r) => r.detail, 'detail', 'gemini-3.8-flash'));
    });

    test('model list is fetched once for two requests', () async {
      final server = FakeGeminiServer();
      final e = _engine(server);
      await e.process(_request());
      await e.process(_request());
      expect(server.listCalls, hasLength(1));
      expect(server.generateCalls, hasLength(2));
      expect(server.generateCalls.every((r) => r.url.path.endsWith('models/gemini-3.8-flash:generateContent')),
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

    test('any listed model can be picked, older ones too', () async {
      for (final id in ['gemini-3.5-pro', 'gemini-3.5-flash-lite-preview-09-2026', 'gemini-2.5-flash']) {
        final server = FakeGeminiServer();
        await _engine(server, preferred: id).process(_request());
        expect(server.generateCalls.first.url.path, contains('models/$id:'));
      }
    });

    test('an unknown preferred model falls back to the default', () async {
      final server = FakeGeminiServer();
      await _engine(server, preferred: 'gemini-9-flash').process(_request());
      expect(server.generateCalls.single.url.path, contains('models/gemini-3.8-flash:'));
    });

    test('nothing usable listed is a server failure', () async {
      final server = FakeGeminiServer(models: [modelEntry('text-embedding-004', methods: ['embedContent'])]);
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
          server.models = [modelEntry('gemini-3.6-flash')];
          return errorResponse(404, 'models/gemini-3.8-flash is not found', statusText: 'NOT_FOUND');
        }
        return textResponse('second try');
      };
      final e = _engine(server);
      // Prime the cache with the old list.
      await e.availableModels();
      server.models = [modelEntry('gemini-3.6-flash')];

      final out = await e.process(_request());

      expect(out, 'second try');
      expect(server.listCalls, hasLength(2));
      expect(server.generateCalls, hasLength(2));
      expect(server.generateCalls.first.url.path, contains('gemini-3.8-flash'));
      expect(server.generateCalls.last.url.path, contains('gemini-3.6-flash'));
    });
  });

  group('thinking config', () {
    test('minimal, then low, then none when thinkingConfig is rejected, and remembered', () async {
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
      expect(calls, 3);
      final levels = [
        for (final b in server.generateCalls.map(FakeGeminiServer.bodyOf))
          ((b['generationConfig'] as Map)['thinkingConfig'] as Map?)?['thinkingLevel'],
      ];
      expect(levels, ['minimal', 'low', null]);

      expect(await e.process(_request()), 'fine');
      expect(calls, 4, reason: 'later requests skip the rejected options');
    });

    test('a model that rejects MINIMAL works with low, and low is remembered per model', () async {
      final server = FakeGeminiServer();
      server.onGenerate = (r, b) {
        final level = ((b['generationConfig'] as Map)['thinkingConfig'] as Map?)?['thinkingLevel'];
        if (level == 'minimal') {
          return errorResponse(400, 'Thinking level MINIMAL is not supported for this model', statusText: 'INVALID_ARGUMENT');
        }
        return textResponse('ok');
      };
      final e = _engine(server);
      expect(await e.process(_request()), 'ok');
      expect(await e.process(_request()), 'ok');
      final levels = [
        for (final b in server.generateCalls.map(FakeGeminiServer.bodyOf))
          ((b['generationConfig'] as Map)['thinkingConfig'] as Map)['thinkingLevel'],
      ];
      expect(levels, ['minimal', 'low', 'low']);

      // Another model still starts with minimal.
      final other = _engine(server, preferred: 'gemini-3.5-flash-lite', cache: e.cache);
      await other.process(_request());
      final last = FakeGeminiServer.bodyOf(server.generateCalls[3]);
      expect(((last['generationConfig'] as Map)['thinkingConfig'] as Map)['thinkingLevel'], 'minimal');
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

    test('thinking: cleanup asks for low thinking in the same single request', () async {
      final server = FakeGeminiServer(onGenerate: (r, b) => textResponse('Hello.'));
      final e = GeminiEngine(apiKey: () async => 'KEY', client: GeminiClient(httpClient: server.client), thinkOnCleanup: true);
      expect(await e.process(_request()), 'Hello.');
      final body = FakeGeminiServer.bodyOf(server.generateCalls.single);
      expect(jsonEncode(body['generationConfig']).toLowerCase(), contains('low'));
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
      expect(id, 'gemini-3.8-flash');
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

void healthProbeTests() {
  group('health probe', () {
    String modelOf(http.Request r) => RegExp(r'models/([^:]+):').firstMatch(r.url.path)!.group(1)!;
    bool isProbe(Map<String, Object?> b) => (b['generationConfig'] as Map)['maxOutputTokens'] == 16;

    List<Map<String, Object?>> models() => [
          modelEntry('gemini-3.8-flash'),
          modelEntry('gemini-3.7-flash'),
          modelEntry('gemini-3.6-flash'),
          modelEntry('gemini-3.5-flash'),
          modelEntry('gemini-3.1-flash'),
          modelEntry('gemini-2.5-flash'),
          modelEntry('gemini-3.5-flash-lite'),
          modelEntry('gemini-3.5-pro'),
        ];

    GeminiEngine probing(
      FakeGeminiServer server, {
      String? preferred,
      GeminiModelCache? cache,
      Duration fast = const Duration(milliseconds: 60),
      Duration probeTimeout = const Duration(milliseconds: 300),
      Duration pickedTimeout = const Duration(milliseconds: 100),
    }) =>
        GeminiEngine(
          apiKey: () async => 'KEY',
          client: GeminiClient(httpClient: server.client),
          cache: cache,
          preferredModel: preferred,
          overloadBackoff: Duration.zero,
          healthProbe: true,
          fastLatency: fast,
          probeTimeout: probeTimeout,
          pickedModelTimeout: pickedTimeout,
        );

    Future<http.Response> after(int ms, http.Response r) => Future.delayed(Duration(milliseconds: ms), () => r);

    test('probes the four newest stable flash models in parallel, plus the pick', () async {
      var inFlight = 0, maxInFlight = 0;
      final server = FakeGeminiServer(models: models());
      server.onGenerate = (r, b) async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 80));
        inFlight--;
        return textResponse('OK');
      };
      final cache = GeminiModelCache();
      final e = probing(server, preferred: 'gemini-3.5-pro', cache: cache);
      await e.availableModels();
      await cache.probing;
      expect(server.generateCalls.map(modelOf).toSet(),
          {'gemini-3.8-flash', 'gemini-3.7-flash', 'gemini-3.6-flash', 'gemini-3.5-flash', 'gemini-3.5-pro'});
      expect(maxInFlight, 5, reason: 'all probes run at once');
      final body = FakeGeminiServer.bodyOf(server.generateCalls.first);
      expect((body['generationConfig'] as Map)['maxOutputTokens'], 16);
    });

    test('records fast, slow and failed with latency, exposed on the model list', () async {
      final server = FakeGeminiServer(models: models());
      server.onGenerate = (r, b) => switch (modelOf(r)) {
            'gemini-3.8-flash' => after(150, textResponse('OK')),
            'gemini-3.6-flash' => errorResponse(503, 'high demand', statusText: 'UNAVAILABLE'),
            'gemini-3.5-flash' => after(900, textResponse('OK')),
            _ => textResponse('OK'),
          };
      final cache = GeminiModelCache();
      final e = probing(server, cache: cache);
      await e.availableModels();
      await cache.probing;

      final byId = {for (final m in await e.availableModels()) m.id: m};
      expect(byId['gemini-3.7-flash']!.health, GeminiHealth.fast);
      expect(byId['gemini-3.7-flash']!.healthLabel, startsWith('Fast · '));
      expect(byId['gemini-3.8-flash']!.health, GeminiHealth.slow);
      expect(byId['gemini-3.8-flash']!.healthLabel, startsWith('Slow · '));
      expect(byId['gemini-3.6-flash']!.health, GeminiHealth.failed);
      expect(byId['gemini-3.5-flash']!.health, GeminiHealth.failed, reason: 'timed out');
      expect(byId['gemini-3.5-flash']!.healthLabel, 'Not responding');
      expect(byId['gemini-3.1-flash']!.health, GeminiHealth.unknown);
      expect(byId['gemini-3.1-flash']!.healthLabel, isNull);
    });

    test('automatic order: fast flash, then slow flash, then flash-lite; failed ones are skipped', () async {
      final server = FakeGeminiServer(models: models());
      var probesDone = false;
      server.onGenerate = (r, b) {
        if (isProbe(b)) {
          return switch (modelOf(r)) {
            'gemini-3.8-flash' => after(150, textResponse('OK')),
            'gemini-3.6-flash' => errorResponse(503, 'down', statusText: 'UNAVAILABLE'),
            _ => textResponse('OK'),
          };
        }
        return errorResponse(429, 'Resource exhausted', statusText: 'RESOURCE_EXHAUSTED');
      };
      final cache = GeminiModelCache();
      final e = probing(server, cache: cache);
      await e.availableModels();
      await cache.probing;
      probesDone = true;
      expect(probesDone, isTrue);
      server.requests.clear();

      await expectLater(e.process(_request()), throwsA(isA<CleanupFailure>()));
      expect(server.generateCalls.map(modelOf), [
        'gemini-3.7-flash',
        'gemini-3.5-flash',
        'gemini-3.8-flash',
        'gemini-3.5-flash-lite',
      ]);
    });

    test('a probe never blocks a dictation', () async {
      final server = FakeGeminiServer(models: models());
      server.onGenerate = (r, b) => isProbe(b) ? after(200, textResponse('OK')) : textResponse('dictated');
      final cache = GeminiModelCache();
      final e = probing(server, cache: cache, probeTimeout: const Duration(seconds: 2));
      final watch = Stopwatch()..start();
      expect(await e.process(_request()), 'dictated');
      expect(watch.elapsedMilliseconds, lessThan(180));
      expect(cache.probing, isNotNull, reason: 'the probe is still running');
      // Without results yet the normal chain is used, newest flash first.
      expect(modelOf(server.generateCalls.firstWhere((r) => !isProbe(FakeGeminiServer.bodyOf(r)))), 'gemini-3.8-flash');
      await cache.probing;
    });

    test('probes at most every six hours', () async {
      var now = DateTime(2026, 1, 1);
      final cache = GeminiModelCache(clock: () => now, ttl: const Duration(days: 2));
      final server = FakeGeminiServer(models: models());
      final e = probing(server, cache: cache);
      await e.availableModels();
      await cache.probing;
      final first = server.generateCalls.length;
      now = now.add(const Duration(hours: 5));
      await e.availableModels();
      await cache.probing;
      expect(server.generateCalls, hasLength(first));
      now = now.add(const Duration(hours: 2));
      await e.availableModels();
      await cache.probing;
      expect(server.generateCalls.length, first * 2);
    });

    test('a different key is probed again', () async {
      final cache = GeminiModelCache();
      final server = FakeGeminiServer(models: models());
      var key = 'A';
      GeminiEngine make() => GeminiEngine(
            apiKey: () async => key,
            client: GeminiClient(httpClient: server.client),
            cache: cache,
            healthProbe: true,
          );
      await make().availableModels();
      await cache.probing;
      final first = server.generateCalls.length;
      key = 'B';
      await make().availableModels();
      await cache.probing;
      expect(server.generateCalls.length, first * 2);
    });

    test('the user pick stays first, but gets a short timeout when the probe found it slow', () async {
      final server = FakeGeminiServer(models: models());
      server.onGenerate = (r, b) {
        if (modelOf(r) == 'gemini-3.6-flash') return after(400, textResponse('late'));
        return textResponse('ok');
      };
      final cache = GeminiModelCache();
      final e = probing(server, preferred: 'gemini-3.6-flash', cache: cache, probeTimeout: const Duration(seconds: 2));
      await e.availableModels();
      await cache.probing;
      expect(cache.healthOf('gemini-3.6-flash'), GeminiHealth.slow);
      server.requests.clear();

      expect(await e.process(_request()), 'ok');
      final models_ = server.generateCalls.map(modelOf).toList();
      expect(models_.first, 'gemini-3.6-flash', reason: 'the pick is still tried first');
      expect(models_, hasLength(greaterThan(1)), reason: 'it timed out after the short timeout and fell back');
    });

    test('the user pick keeps first place and the normal timeout when it is healthy', () async {
      final server = FakeGeminiServer(models: models());
      server.onGenerate = (r, b) => modelOf(r) == 'gemini-3.6-flash' && !isProbe(b) ? after(250, textResponse('picked')) : textResponse('OK');
      final cache = GeminiModelCache();
      final e = probing(server, preferred: 'gemini-3.6-flash', cache: cache);
      await e.availableModels();
      await cache.probing;
      expect(cache.healthOf('gemini-3.6-flash'), GeminiHealth.fast);
      server.requests.clear();
      expect(await e.process(_request()), 'picked');
    });

    test('probing is off unless asked for', () async {
      final server = FakeGeminiServer(models: models());
      final e = _engine(server);
      await e.availableModels();
      expect(server.generateCalls, isEmpty);
    });
  });
}

void fallbackChainTests() {
  group('model fallback chain', () {
    String modelOf(http.Request r) => RegExp(r'models/([^:]+):').firstMatch(r.url.path)!.group(1)!;

    test('503 is retried once on the same model', () async {
      final server = FakeGeminiServer();
      var calls = 0;
      server.onGenerate = (r, b) =>
          ++calls == 1 ? errorResponse(503, 'This model is currently experiencing high demand.', statusText: 'UNAVAILABLE') : textResponse('ok');
      expect(await _engine(server).process(_request()), 'ok');
      expect(server.generateCalls.map(modelOf), ['gemini-3.8-flash', 'gemini-3.8-flash']);
    });

    test('a persistent 503 moves on to the newest stable flash-lite', () async {
      final server = FakeGeminiServer();
      server.onGenerate = (r, b) => modelOf(r) == 'gemini-3.8-flash'
          ? errorResponse(503, 'high demand', statusText: 'UNAVAILABLE')
          : textResponse('lite answer');
      expect(await _engine(server).process(_request()), 'lite answer');
      expect(server.generateCalls.map(modelOf), ['gemini-3.8-flash', 'gemini-3.8-flash', 'gemini-3.5-flash-lite']);
    });

    test('a per-minute 429 moves on without retrying the same model', () async {
      final server = FakeGeminiServer();
      server.onGenerate = (r, b) => modelOf(r) == 'gemini-3.8-flash'
          ? errorResponse(429, 'Resource exhausted', statusText: 'RESOURCE_EXHAUSTED')
          : textResponse('ok');
      expect(await _engine(server).process(_request()), 'ok');
      expect(server.generateCalls.map(modelOf), ['gemini-3.8-flash', 'gemini-3.5-flash-lite']);
    });

    test('everything failing rethrows the last failure so the pipeline can fall back', () async {
      final server = FakeGeminiServer(onGenerate: (r, b) => errorResponse(503, 'high demand', statusText: 'UNAVAILABLE'));
      await expectLater(
        _engine(server).process(_request()),
        throwsA(isA<CleanupFailure>().having((f) => f.kind, 'kind', CleanupFailureKind.server)),
      );
      expect(server.generateCalls, hasLength(4));
    });

    test('limit: 0 is remembered, surfaced on the model list and skipped next time', () async {
      final server = FakeGeminiServer();
      server.onGenerate = (r, b) => modelOf(r) == 'gemini-3.5-pro'
          ? errorResponse(429, 'Quota exceeded for metric ..., limit: 0', statusText: 'RESOURCE_EXHAUSTED')
          : textResponse('ok');
      final cache = GeminiModelCache();
      final e = _engine(server, preferred: 'gemini-3.5-pro', cache: cache);
      expect(await e.process(_request()), 'ok');
      expect(server.generateCalls.map(modelOf), ['gemini-3.5-pro', 'gemini-3.5-flash-lite']);

      final models = await e.availableModels();
      expect(models.firstWhere((m) => m.id == 'gemini-3.5-pro').freeTierUnavailable, isTrue);
      expect(models.firstWhere((m) => m.id == 'gemini-3.8-flash').freeTierUnavailable, isFalse);
    });

    test('the default skips a model known to have no free tier', () async {
      final server = FakeGeminiServer();
      server.onGenerate = (r, b) => modelOf(r) == 'gemini-3.8-flash'
          ? errorResponse(429, 'limit: 0', statusText: 'RESOURCE_EXHAUSTED')
          : textResponse('ok');
      final cache = GeminiModelCache();
      await _engine(server, cache: cache).process(_request());
      server.requests.clear();
      await _engine(server, cache: cache).process(_request());
      expect(server.generateCalls.map(modelOf), ['gemini-3.5-flash-lite']);
    });

    test('limit: 0 everywhere is the distinct failure kind', () async {
      final server = FakeGeminiServer(onGenerate: (r, b) => errorResponse(429, 'limit: 0', statusText: 'RESOURCE_EXHAUSTED'));
      await expectLater(
        _engine(server).process(_request()),
        throwsA(isA<CleanupFailure>().having((f) => f.kind, 'kind', CleanupFailureKind.modelNotOnFreeTier)),
      );
      expect(CleanupFailureKind.modelNotOnFreeTier.cloudFallbackEligible, isTrue);
    });

    test('"no longer available to new users" (any status) marks the model unavailable and moves on', () async {
      for (final status in [400, 404, 403]) {
        final server = FakeGeminiServer();
        server.onGenerate = (r, b) => modelOf(r) == 'gemini-3.5-pro'
            ? errorResponse(status, 'This model models/gemini-3.5-pro is no longer available to new users. Please update your code.',
                statusText: 'FAILED_PRECONDITION')
            : textResponse('ok');
        final cache = GeminiModelCache();
        final e = _engine(server, preferred: 'gemini-3.5-pro', cache: cache);
        expect(await e.process(_request()), 'ok', reason: 'status $status');
        expect(server.generateCalls.map(modelOf), ['gemini-3.5-pro', 'gemini-3.5-flash-lite']);

        final pro = (await e.availableModels()).firstWhere((m) => m.id == 'gemini-3.5-pro');
        expect(pro.unavailable, isTrue);
        expect(pro.unavailableReason, contains('no longer available'));

        // Next time the unavailable pick is skipped up front.
        server.requests.clear();
        await e.process(_request());
        expect(server.generateCalls.map(modelOf), ['gemini-3.8-flash']);
      }
    });

    test('"Developer instruction is not enabled" is treated the same way', () async {
      final server = FakeGeminiServer();
      server.onGenerate = (r, b) => modelOf(r) == 'gemini-3.8-flash'
          ? errorResponse(400, 'Developer instruction is not enabled for this model', statusText: 'INVALID_ARGUMENT')
          : textResponse('ok');
      final cache = GeminiModelCache();
      expect(await _engine(server, cache: cache).process(_request()), 'ok');
      server.requests.clear();
      await _engine(server, cache: cache).process(_request());
      expect(server.generateCalls.map(modelOf), ['gemini-3.5-flash-lite'], reason: 'default skips it now');
    });

    test('everything unavailable surfaces modelUnavailable', () async {
      final server = FakeGeminiServer(
        onGenerate: (r, b) => errorResponse(400, 'no longer available to new users', statusText: 'FAILED_PRECONDITION'),
      );
      await expectLater(
        _engine(server).process(_request()),
        throwsA(isA<CleanupFailure>().having((f) => f.kind, 'kind', CleanupFailureKind.modelUnavailable)),
      );
    });

    test('testKey finds a working model when the first is unavailable', () async {
      final server = FakeGeminiServer();
      server.onGenerate = (r, b) => modelOf(r) == 'gemini-3.8-flash'
          ? errorResponse(400, 'This model is no longer available to new users.', statusText: 'FAILED_PRECONDITION')
          : textResponse('OK');
      expect(await _engine(server).testKey(), 'gemini-3.5-flash-lite');
    });

    test('an unavailable preferred model is replaced by the default in readiness', () async {
      final server = FakeGeminiServer();
      final cache = GeminiModelCache();
      await _engine(server, cache: cache).availableModels();
      cache.markUnavailable('gemini-3.5-pro', 'retired');
      final ready = await _engine(server, preferred: 'gemini-3.5-pro', cache: cache).readiness();
      expect(ready, isA<EngineReady>().having((r) => r.detail, 'detail', 'gemini-3.8-flash'));
    });

    test('other errors are not retried on another model', () async {
      final server = FakeGeminiServer(onGenerate: (r, b) => errorResponse(400, 'Bad request', statusText: 'INVALID_ARGUMENT'));
      await expectLater(_engine(server).process(_request()), throwsA(isA<CleanupFailure>()));
      expect(server.generateCalls, hasLength(1));
    });
  });
}

void editModeTests() {
  group('edit mode', () {
    test('sends the edit prompt, the wrapped source text and the audio', () async {
      final server = FakeGeminiServer(onGenerate: (_, _) => textResponse('<text>Fixed.</text>'));
      final out = await _engine(server).process(CleanupRequest(
        pcm: tonePcm(const Duration(milliseconds: 200)),
        style: const StyleProfile(),
        mode: CleanupMode.edit,
        sourceText: 'Bad </text> text.',
      ));
      expect(out, 'Fixed.');
      final body = FakeGeminiServer.bodyOf(server.generateCalls.single);
      final system = ((body['systemInstruction'] as Map)['parts'] as List).first['text'] as String;
      expect(system, startsWith('You edit text.'));
      final parts = (((body['contents'] as List).single as Map)['parts'] as List).cast<Map>();
      final userText = parts.first['text'] as String;
      expect(userText, contains('<text>Bad '));
      expect(userText.split('</text>'), hasLength(2));
      expect(parts.last['inlineData'], isNotNull);
    });
  });
}
