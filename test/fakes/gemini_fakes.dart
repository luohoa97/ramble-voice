// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A realistic `GET v1beta/models` entry.
Map<String, Object?> modelEntry(
  String id, {
  List<String> methods = const ['generateContent', 'countTokens'],
  String? displayName,
}) => {
  'name': 'models/$id',
  'displayName': displayName ?? id,
  'inputTokenLimit': 1048576,
  'outputTokenLimit': 65536,
  'supportedGenerationMethods': methods,
};

/// A model list with the awkward neighbours the selector must ignore.
List<Map<String, Object?>> realisticModels() => [
  modelEntry('gemini-2.0-flash'),
  modelEntry('gemini-2.5-flash'),
  modelEntry('gemini-2.5-flash-lite'),
  modelEntry('gemini-3.1-flash-lite'),
  modelEntry('gemini-3.5-flash-lite'),
  modelEntry('gemini-3.5-flash-lite-preview-09-2026'),
  modelEntry('gemini-3.5-flash-lite-tts'),
  modelEntry('gemini-3.5-flash-lite-live'),
  modelEntry('gemini-3.8-flash'),
  modelEntry('gemini-3.5-pro'),
  modelEntry('text-embedding-004', methods: ['embedContent']),
  modelEntry('gemini-embedding-001', methods: ['embedContent']),
  modelEntry('gemini-3.9-flash-lite', methods: ['countTokens']),
  modelEntry('gemini-flash-latest'),
  modelEntry('gemini-flash-lite-latest'),
  modelEntry('gemini-3-flash-preview'),
  modelEntry('gemini-2.5-flash-image'),
  modelEntry('gemini-omni-1.1-flash'),
];

http.Response jsonResponse(
  Object body, [
  int status = 200,
  Map<String, String> headers = const {},
]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

http.Response textResponse(String text) => jsonResponse({
  'candidates': [
    {
      'content': {
        'role': 'model',
        'parts': [
          {'text': text},
        ],
      },
      'finishReason': 'STOP',
    },
  ],
});

http.Response errorResponse(
  int status,
  String message, {
  String? statusText,
  List<Map<String, Object?>> details = const [],
}) => jsonResponse({
  'error': {
    'code': status,
    'message': message,
    'status': ?statusText,
    if (details.isNotEmpty) 'details': details,
  },
}, status);

/// Records every request and answers with [onList] / [onGenerate].
class FakeGeminiServer {
  FakeGeminiServer({List<Map<String, Object?>>? models, this.onGenerate})
    : models = models ?? realisticModels();

  List<Map<String, Object?>> models;

  /// Handles `:generateContent`. Defaults to a fixed text response.
  FutureOr<http.Response> Function(
    http.Request request,
    Map<String, Object?> body,
  )?
  onGenerate;

  final List<http.Request> requests = [];

  List<http.Request> get listCalls => requests
      .where((r) => r.method == 'GET' && r.url.path.endsWith('/models'))
      .toList();
  List<http.Request> get generateCalls => requests
      .where(
        (r) => r.method == 'POST' && r.url.path.endsWith(':generateContent'),
      )
      .toList();

  static Map<String, Object?> bodyOf(http.Request r) =>
      (jsonDecode(r.body) as Map).cast<String, Object?>();

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    if (request.method == 'GET') {
      return jsonResponse({'models': models});
    }
    final handler = onGenerate;
    return handler == null
        ? textResponse('ok')
        : await handler(request, bodyOf(request));
  });
}
