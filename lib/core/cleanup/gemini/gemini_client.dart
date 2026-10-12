// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../cleanup_engine.dart';

/// Thin REST client for the Gemini Developer API. There is no maintained
/// official Dart SDK, and the API needs only two calls.
class GeminiClient {
  GeminiClient({http.Client? httpClient, this.timeout = const Duration(seconds: 90)})
      : _http = httpClient ?? http.Client();

  static final Uri base = Uri.parse('https://generativelanguage.googleapis.com/v1beta/');

  final http.Client _http;
  final Duration timeout;

  Map<String, String> _headers(String key) => {
        'x-goog-api-key': key,
        'content-type': 'application/json',
      };

  /// `GET models`, all pages.
  Future<List<Map<String, Object?>>> listModels(String apiKey) async {
    final models = <Map<String, Object?>>[];
    String? pageToken;
    do {
      final uri = base.resolve('models').replace(queryParameters: {
        'pageSize': '1000',
        'pageToken': ?pageToken,
      });
      final json = await _send(() => _http.get(uri, headers: _headers(apiKey)));
      models.addAll(((json['models'] as List?) ?? const []).cast<Map<String, Object?>>());
      pageToken = json['nextPageToken'] as String?;
    } while (pageToken != null && pageToken.isNotEmpty);
    return models;
  }

  /// `POST models/{model}:generateContent` with a system instruction, a user
  /// text part and inline WAV audio. Returns the response text.
  Future<String> generateFromAudio({
    required String apiKey,
    required String model,
    required String systemInstruction,
    required String userText,
    required List<int> wav,
    bool minimalThinking = true,
    double temperature = 0.2,
    int maxOutputTokens = 8192,
  }) async {
    final body = <String, Object?>{
      'systemInstruction': {
        'parts': [
          {'text': systemInstruction},
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': userText},
            {
              'inlineData': {'mimeType': 'audio/wav', 'data': base64Encode(wav)},
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': temperature,
        'maxOutputTokens': maxOutputTokens,
        'responseMimeType': 'text/plain',
        if (minimalThinking) 'thinkingConfig': {'thinkingLevel': 'minimal'},
      },
    };
    final uri = base.resolve('models/$model:generateContent');
    final json = await _send(
      () => _http.post(uri, headers: _headers(apiKey), body: jsonEncode(body)),
    );
    return extractText(json);
  }

  static String extractText(Map<String, Object?> json) {
    final feedback = json['promptFeedback'] as Map<String, Object?>?;
    if (feedback?['blockReason'] != null) {
      throw CleanupFailure(
        CleanupFailureKind.blocked,
        'Gemini blocked this request (${feedback!['blockReason']}).',
      );
    }
    final candidates = (json['candidates'] as List?) ?? const [];
    if (candidates.isEmpty) {
      throw const CleanupFailure(CleanupFailureKind.emptyResult, 'Gemini returned no result.');
    }
    final first = candidates.first as Map<String, Object?>;
    final reason = first['finishReason'] as String?;
    if (reason == 'SAFETY' || reason == 'PROHIBITED_CONTENT' || reason == 'BLOCKLIST') {
      throw CleanupFailure(CleanupFailureKind.blocked, 'Gemini blocked the response ($reason).');
    }
    final parts = ((first['content'] as Map?)?['parts'] as List?) ?? const [];
    final text = parts
        .cast<Map<String, Object?>>()
        .where((p) => p['thought'] != true)
        .map((p) => p['text'] as String? ?? '')
        .join();
    return text;
  }

  Future<Map<String, Object?>> _send(Future<http.Response> Function() request) async {
    final http.Response res;
    try {
      res = await request().timeout(timeout);
    } on TimeoutException catch (e) {
      throw CleanupFailure(CleanupFailureKind.noNetwork, 'Gemini did not respond in time.', cause: e);
    } on SocketException catch (e) {
      throw CleanupFailure(CleanupFailureKind.noNetwork, 'No internet connection.', cause: e);
    } on http.ClientException catch (e) {
      throw CleanupFailure(CleanupFailureKind.noNetwork, 'No internet connection.', cause: e);
    }
    Map<String, Object?> json;
    try {
      json = (jsonDecode(utf8.decode(res.bodyBytes)) as Map).cast<String, Object?>();
    } catch (_) {
      json = const {};
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return json;
    throw mapError(res.statusCode, json, res.headers);
  }

  /// Maps an error response to a [CleanupFailure].
  static CleanupFailure mapError(int status, Map<String, Object?> json, [Map<String, String> headers = const {}]) {
    final error = (json['error'] as Map?)?.cast<String, Object?>() ?? const {};
    final message = error['message'] as String? ?? 'HTTP $status';
    final statusText = error['status'] as String? ?? '';
    final details = ((error['details'] as List?) ?? const []).whereType<Map>().toList();

    String? reason;
    Duration? retryAfter;
    var daily = false;
    for (final d in details) {
      final type = d['@type'] as String? ?? '';
      if (type.endsWith('ErrorInfo')) reason = d['reason'] as String?;
      if (type.endsWith('RetryInfo')) retryAfter = parseDuration(d['retryDelay'] as String?);
      if (type.endsWith('QuotaFailure')) {
        for (final v in (d['violations'] as List? ?? const []).whereType<Map>()) {
          final id = '${v['quotaId'] ?? ''} ${v['quotaMetric'] ?? ''}';
          if (id.contains('PerDay')) daily = true;
        }
      }
    }
    retryAfter ??= int.tryParse(headers['retry-after'] ?? '') == null
        ? null
        : Duration(seconds: int.parse(headers['retry-after']!));

    if (reason == 'API_KEY_INVALID' || status == 401 || (status == 403 && statusText == 'PERMISSION_DENIED')) {
      return CleanupFailure(CleanupFailureKind.invalidApiKey, 'Gemini rejected the API key. Check it in Settings.');
    }
    if (status == 429 || statusText == 'RESOURCE_EXHAUSTED') {
      return daily
          ? const CleanupFailure(
              CleanupFailureKind.dailyQuotaExceeded,
              "Gemini's free daily limit is used up. It resets at midnight Pacific time.",
            )
          : CleanupFailure(
              CleanupFailureKind.rateLimited,
              'Gemini is rate limiting requests. Try again shortly.',
              retryAfter: retryAfter,
            );
    }
    if (status == 413 || message.contains('exceeds the maximum')) {
      return CleanupFailure(CleanupFailureKind.audioTooLong, 'The audio is too long for one Gemini request.');
    }
    if (status >= 500) {
      return CleanupFailure(CleanupFailureKind.server, 'Gemini is having problems ($status).', retryAfter: retryAfter);
    }
    return CleanupFailure(CleanupFailureKind.unknown, 'Gemini error $status: $message');
  }

  /// Parses protobuf durations like "34s" or "1.5s".
  static Duration? parseDuration(String? s) {
    if (s == null) return null;
    final m = RegExp(r'^(\d+(?:\.\d+)?)s$').firstMatch(s.trim());
    if (m == null) return null;
    return Duration(milliseconds: (double.parse(m.group(1)!) * 1000).round());
  }

  void close() => _http.close();
}
