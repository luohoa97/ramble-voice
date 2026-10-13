// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ramble_voice/core/audio/pcm.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/cleanup/gemini/gemini_client.dart';

import '../fakes/gemini_fakes.dart';
import '../fakes/pcm_fixtures.dart';

Future<CleanupFailure> _failure(Future<Object?> f) async {
  try {
    await f;
  } on CleanupFailure catch (e) {
    return e;
  }
  fail('expected a CleanupFailure');
}

Future<String> _generate(GeminiClient c, {Uint8List? wav, bool minimalThinking = true}) => c.generateFromAudio(
      apiKey: 'KEY',
      model: 'gemini-3.5-flash-lite',
      systemInstruction: 'SYSTEM',
      userText: 'USER',
      wav: wav ?? WavEncoder.encode(tonePcm(const Duration(milliseconds: 50))),
      minimalThinking: minimalThinking,
    );

GeminiClient _clientFor(http.Response Function(http.Request) h, {Duration? timeout}) => GeminiClient(
      httpClient: MockClient((r) async => h(r)),
      timeout: timeout ?? const Duration(seconds: 5),
    );

void main() {
  group('generateFromAudio request', () {
    test('url, headers, system instruction, audio and thinking config', () async {
      final server = FakeGeminiServer(onGenerate: (r, b) => textResponse('hello'));
      final client = GeminiClient(httpClient: server.client);
      final pcm = tonePcm(const Duration(milliseconds: 80));

      final text = await _generate(client, wav: WavEncoder.encode(pcm));

      expect(text, 'hello');
      final req = server.generateCalls.single;
      expect(req.url.toString(),
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent');
      expect(req.headers['x-goog-api-key'], 'KEY');
      expect(req.headers['content-type'], contains('application/json'));
      expect(req.url.queryParameters.containsKey('key'), isFalse, reason: 'key must not be in the URL');

      final body = FakeGeminiServer.bodyOf(req);
      expect(((body['systemInstruction'] as Map)['parts'] as List).single, {'text': 'SYSTEM'});
      final content = (body['contents'] as List).single as Map;
      expect(content['role'], 'user');
      final parts = (content['parts'] as List).cast<Map>();
      expect(parts[0], {'text': 'USER'});
      final inline = parts[1]['inlineData'] as Map;
      expect(inline['mimeType'], 'audio/wav');
      final wav = base64Decode(inline['data'] as String);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(WavEncoder.decode(Uint8List.fromList(wav)), pcm);

      final gen = body['generationConfig'] as Map;
      expect(gen['thinkingConfig'], {'thinkingLevel': 'minimal'});
      expect(gen['responseMimeType'], 'text/plain');
      expect(gen['temperature'], 0.2);
      expect(gen['maxOutputTokens'], 8192);
      expect(body.containsKey('tools'), isFalse);
    });

    test('thinkingConfig is omitted when minimalThinking is false', () async {
      final server = FakeGeminiServer();
      await _generate(GeminiClient(httpClient: server.client), minimalThinking: false);
      final gen = FakeGeminiServer.bodyOf(server.generateCalls.single)['generationConfig'] as Map;
      expect(gen.containsKey('thinkingConfig'), isFalse);
    });
  });

  group('listModels', () {
    test('follows pagination and sends the key header', () async {
      final seen = <http.Request>[];
      final client = GeminiClient(
        httpClient: MockClient((r) async {
          seen.add(r);
          final token = r.url.queryParameters['pageToken'];
          return token == null
              ? jsonResponse({
                  'models': [modelEntry('gemini-3.5-flash-lite')],
                  'nextPageToken': 'page2',
                })
              : jsonResponse({
                  'models': [modelEntry('gemini-3.1-flash-lite')],
                });
        }),
      );
      final models = await client.listModels('KEY');
      expect(models.map((m) => m['name']), ['models/gemini-3.5-flash-lite', 'models/gemini-3.1-flash-lite']);
      expect(seen, hasLength(2));
      expect(seen.first.url.path, '/v1beta/models');
      expect(seen.first.url.queryParameters['pageSize'], '1000');
      expect(seen.last.url.queryParameters['pageToken'], 'page2');
      expect(seen.every((r) => r.headers['x-goog-api-key'] == 'KEY'), isTrue);
    });

    test('empty response is an empty list', () async {
      final client = _clientFor((_) => jsonResponse({}));
      expect(await client.listModels('KEY'), isEmpty);
    });
  });

  group('extractText', () {
    Map<String, Object?> candidate(List<Map<String, Object?>> parts, {String? finish = 'STOP'}) => {
          'candidates': [
            {
              'content': {'parts': parts},
              'finishReason': ?finish,
            },
          ],
        };

    test('joins text parts and skips thoughts', () {
      final text = GeminiClient.extractText(candidate([
        {'text': 'let me think', 'thought': true},
        {'text': 'Hello '},
        {'text': 'world.'},
      ]));
      expect(text, 'Hello world.');
    });

    test('blockReason is blocked', () {
      expect(
        () => GeminiClient.extractText({
          'promptFeedback': {'blockReason': 'PROHIBITED_CONTENT'},
        }),
        throwsA(isA<CleanupFailure>().having((f) => f.kind, 'kind', CleanupFailureKind.blocked)),
      );
    });

    test('finishReason SAFETY (and friends) is blocked', () {
      for (final reason in ['SAFETY', 'PROHIBITED_CONTENT', 'BLOCKLIST']) {
        expect(
          () => GeminiClient.extractText(candidate([], finish: reason)),
          throwsA(isA<CleanupFailure>().having((f) => f.kind, 'kind', CleanupFailureKind.blocked)),
          reason: reason,
        );
      }
    });

    test('no candidates is emptyResult', () {
      expect(
        () => GeminiClient.extractText({'candidates': []}),
        throwsA(isA<CleanupFailure>().having((f) => f.kind, 'kind', CleanupFailureKind.emptyResult)),
      );
      expect(
        () => GeminiClient.extractText({}),
        throwsA(isA<CleanupFailure>().having((f) => f.kind, 'kind', CleanupFailureKind.emptyResult)),
      );
    });

    test('a candidate without content yields an empty string', () {
      expect(GeminiClient.extractText({'candidates': [{'finishReason': 'STOP'}]}), '');
    });
  });

  group('error mapping', () {
    test('400 API_KEY_INVALID is invalidApiKey', () async {
      final c = _clientFor((_) => errorResponse(400, 'API key not valid. Please pass a valid API key.',
          statusText: 'INVALID_ARGUMENT',
          details: [
            {'@type': 'type.googleapis.com/google.rpc.ErrorInfo', 'reason': 'API_KEY_INVALID'},
          ]));
      expect((await _failure(_generate(c))).kind, CleanupFailureKind.invalidApiKey);
    });

    test('401 and 403 PERMISSION_DENIED are invalidApiKey', () async {
      expect((await _failure(_generate(_clientFor((_) => errorResponse(401, 'no'))))).kind,
          CleanupFailureKind.invalidApiKey);
      expect(
          (await _failure(_generate(_clientFor((_) => errorResponse(403, 'no', statusText: 'PERMISSION_DENIED')))))
              .kind,
          CleanupFailureKind.invalidApiKey);
    });

    test('429 with RetryInfo is rateLimited with retryAfter', () async {
      final c = _clientFor((_) => errorResponse(429, 'Resource exhausted', statusText: 'RESOURCE_EXHAUSTED', details: [
            {
              '@type': 'type.googleapis.com/google.rpc.QuotaFailure',
              'violations': [
                {'quotaMetric': 'generativelanguage.googleapis.com/generate_content_free_tier_requests', 'quotaId': 'GenerateRequestsPerMinutePerProjectPerModel-FreeTier'},
              ],
            },
            {'@type': 'type.googleapis.com/google.rpc.RetryInfo', 'retryDelay': '17s'},
          ]));
      final f = await _failure(_generate(c));
      expect(f.kind, CleanupFailureKind.rateLimited);
      expect(f.retryAfter, const Duration(seconds: 17));
    });

    test('429 with a PerDay quota is dailyQuotaExceeded', () async {
      final c = _clientFor((_) => errorResponse(429, 'quota', statusText: 'RESOURCE_EXHAUSTED', details: [
            {
              '@type': 'type.googleapis.com/google.rpc.QuotaFailure',
              'violations': [
                {'quotaId': 'GenerateRequestsPerDayPerProjectPerModel-FreeTier'},
              ],
            },
          ]));
      expect((await _failure(_generate(c))).kind, CleanupFailureKind.dailyQuotaExceeded);
    });

    test('429 falls back to the Retry-After header', () async {
      final c = _clientFor((_) => jsonResponse({'error': {'message': 'slow down'}}, 429, {'retry-after': '9'}));
      final f = await _failure(_generate(c));
      expect(f.kind, CleanupFailureKind.rateLimited);
      expect(f.retryAfter, const Duration(seconds: 9));
    });

    test('5xx is server', () async {
      for (final code in [500, 502, 503, 504]) {
        final f = await _failure(_generate(_clientFor((_) => errorResponse(code, 'overloaded', statusText: 'UNAVAILABLE'))));
        expect(f.kind, CleanupFailureKind.server, reason: '$code');
      }
    });

    test('413 and "exceeds the maximum" are audioTooLong', () async {
      expect((await _failure(_generate(_clientFor((_) => errorResponse(413, 'too big'))))).kind,
          CleanupFailureKind.audioTooLong);
      expect(
          (await _failure(_generate(_clientFor((_) => errorResponse(400, 'request exceeds the maximum size'))))).kind,
          CleanupFailureKind.audioTooLong);
    });

    test('other 4xx is unknown and keeps the message', () async {
      final f = await _failure(_generate(_clientFor((_) => errorResponse(404, 'models/x is not found'))));
      expect(f.kind, CleanupFailureKind.unknown);
      expect(f.message, contains('404'));
      expect(f.message, contains('models/x is not found'));
    });

    test('non-JSON error body still maps by status', () async {
      final c = _clientFor((_) => http.Response('<html>bad gateway</html>', 502));
      expect((await _failure(_generate(c))).kind, CleanupFailureKind.server);
    });
  });

  group('network errors', () {
    test('SocketException is noNetwork', () async {
      final c = GeminiClient(httpClient: MockClient((_) async => throw const SocketException('unreachable')));
      expect((await _failure(_generate(c))).kind, CleanupFailureKind.noNetwork);
    });

    test('ClientException is noNetwork', () async {
      final c = GeminiClient(httpClient: MockClient((_) async => throw http.ClientException('boom')));
      expect((await _failure(_generate(c))).kind, CleanupFailureKind.noNetwork);
      expect((await _failure(c.listModels('K'))).kind, CleanupFailureKind.noNetwork);
    });

    test('timeout is timedOut', () async {
      final c = GeminiClient(
        httpClient: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return textResponse('late');
        }),
        timeout: const Duration(milliseconds: 50),
      );
      final f = await _failure(_generate(c));
      expect(f.kind, CleanupFailureKind.timedOut);
      expect(f.cause, isA<TimeoutException>());
      await Future<void>.delayed(const Duration(milliseconds: 450));
    });
  });

  group('parseDuration', () {
    test('parses protobuf seconds', () {
      expect(GeminiClient.parseDuration('17s'), const Duration(seconds: 17));
      expect(GeminiClient.parseDuration('1.5s'), const Duration(milliseconds: 1500));
      expect(GeminiClient.parseDuration('0.25s'), const Duration(milliseconds: 250));
      expect(GeminiClient.parseDuration(' 34s '), const Duration(seconds: 34));
    });

    test('rejects other shapes', () {
      expect(GeminiClient.parseDuration(null), isNull);
      expect(GeminiClient.parseDuration(''), isNull);
      expect(GeminiClient.parseDuration('5m'), isNull);
      expect(GeminiClient.parseDuration('abc'), isNull);
      expect(GeminiClient.parseDuration('-3s'), isNull);
    });
  });
}
