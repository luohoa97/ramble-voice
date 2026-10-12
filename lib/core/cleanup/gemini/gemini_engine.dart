// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import '../../audio/pcm.dart';
import '../cleanup_engine.dart';
import '../cleanup_prompt.dart';
import 'gemini_client.dart';
import 'gemini_models.dart';

/// How hard the model "thinks" before answering. Cleanup wants the least.
enum GeminiThinking {
  minimal('minimal'),
  low('low'),

  /// No thinkingConfig at all (the model rejected it).
  none('');

  const GeminiThinking(this.level);
  final String level;
}

/// Caches the model list (fetched at most once a day) and what was learned
/// about each model: which thinking level it accepts and whether it has any
/// free-tier quota. The learned facts outlive a list refresh.
class GeminiModelCache {
  GeminiModelCache({this.ttl = const Duration(hours: 24), DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _clock;
  List<GeminiModelInfo>? _models;
  DateTime? _fetchedAt;
  String? _forKey;
  final _thinking = <String, GeminiThinking>{};
  final _noFreeTier = <String>{};
  final _unavailable = <String, String>{};

  List<GeminiModelInfo>? get(String key) {
    if (_models == null || _forKey != key || _fetchedAt == null) return null;
    return _clock().difference(_fetchedAt!) > ttl ? null : annotate(_models!);
  }

  void put(String key, List<GeminiModelInfo> models) {
    if (_forKey != key) {
      _thinking.clear();
      _noFreeTier.clear();
      _unavailable.clear();
    }
    _models = models;
    _forKey = key;
    _fetchedAt = _clock();
  }

  void invalidate() => _models = null;

  /// The thinking mode to try first for [modelId].
  GeminiThinking thinkingFor(String modelId) => _thinking[modelId] ?? GeminiThinking.minimal;

  void rememberThinking(String modelId, GeminiThinking mode) => _thinking[modelId] = mode;

  void markFreeTierUnavailable(String modelId) => _noFreeTier.add(modelId);

  void markUnavailable(String modelId, String reason) => _unavailable[modelId] = reason;

  /// [models] with [GeminiModelInfo.freeTierUnavailable] and
  /// [GeminiModelInfo.unavailableReason] applied.
  List<GeminiModelInfo> annotate(List<GeminiModelInfo> models) => [
        for (final m in models)
          if (_noFreeTier.contains(m.id) || _unavailable.containsKey(m.id))
            m.copyWith(freeTierUnavailable: _noFreeTier.contains(m.id) ? true : null, unavailableReason: _unavailable[m.id])
          else
            m,
      ];
}

/// Cloud cleanup with the user's own Gemini API key.
///
/// Any Pro, Flash or Flash-Lite model with audio input can be used; the
/// default is the newest stable Flash. When a model is overloaded, rate
/// limited or has no quota on this key, the newest Flash-Lite is tried next,
/// and after that the pipeline falls back to the on-device model.
class GeminiEngine implements CleanupEngine {
  GeminiEngine({
    required this.apiKey,
    required this.client,
    GeminiModelCache? cache,
    this.preferredModel,
    this.overloadBackoff = const Duration(milliseconds: 1500),
  }) : cache = cache ?? GeminiModelCache();

  /// Returns the key, or null when none is configured.
  final Future<String?> Function() apiKey;
  final GeminiClient client;
  final GeminiModelCache cache;

  /// A user-picked model id from [availableModels]; unknown ids are ignored.
  final String? preferredModel;

  /// Wait before the single retry after a 503 "high demand".
  final Duration overloadBackoff;

  @override
  EngineKind get kind => EngineKind.gemini;

  /// Inline requests are capped at 20 MB including base64 overhead (4/3),
  /// which is about 7.8 minutes of 16 kHz mono WAV. Stay well under it.
  @override
  Duration get maxAudioPerRequest => const Duration(minutes: 7);

  Future<String> _key() async {
    final k = (await apiKey())?.trim();
    if (k == null || k.isEmpty) {
      throw const CleanupFailure(CleanupFailureKind.missingApiKey, 'Add a Gemini API key in Settings.');
    }
    return k;
  }

  /// Every usable Pro, Flash and Flash-Lite model for this key, best first,
  /// with [GeminiModelInfo.freeTierUnavailable] set for models that answered
  /// "limit: 0".
  Future<List<GeminiModelInfo>> availableModels({bool refresh = false}) async {
    final key = await _key();
    final cached = refresh ? null : cache.get(key);
    if (cached != null) return cached;
    final models = GeminiModelSelector.parse(await client.listModels(key));
    cache.put(key, models);
    return cache.annotate(models);
  }

  Future<GeminiModelInfo> resolveModel({bool refresh = false}) async {
    final models = await availableModels(refresh: refresh);
    var model = GeminiModelSelector.choose(models, preferred: preferredModel);
    if (model != null && model.unavailable) model = GeminiModelSelector.defaultModel(models) ?? model;
    if (model == null) {
      throw const CleanupFailure(
        CleanupFailureKind.server,
        'Google did not list any Gemini model that can transcribe audio for this key.',
      );
    }
    return model;
  }

  @override
  Future<EngineReadiness> readiness() async {
    try {
      final model = await resolveModel();
      return EngineReady(detail: model.id);
    } on CleanupFailure catch (f) {
      return EngineNotReady(f.kind, f.message);
    }
  }

  /// Verifies the key end to end with a tiny silent clip, which also proves
  /// the resolved model accepts audio.
  Future<String> testKey() async {
    await resolveModel(refresh: true);
    final key = await _key();
    final wav = WavEncoder.encode(Uint8List(Pcm.bytesFor(const Duration(milliseconds: 500))));
    // Walk the same chain as process(), so a retired or unsuitable model does
    // not fail the test while another one works.
    final chain = _chain(await availableModels());
    CleanupFailure? last;
    for (var i = 0; i < chain.length; i++) {
      final model = chain[i];
      try {
        await _generate(
          key,
          model,
          systemInstruction: 'Reply with the single word OK.',
          userText: 'Test.',
          wav: wav,
          maxOutputTokens: 256,
        );
        return model.id;
      } on CleanupFailure catch (f) {
        _remember(model, f);
        if (!_tryNextModel(f)) rethrow;
        last = f;
      }
    }
    throw last ?? const CleanupFailure(CleanupFailureKind.unknown, 'No Gemini model could be used.');
  }

  /// One call to [model], adapting the thinking config to what the model
  /// accepts: minimal, then low, then none. The result is remembered per model.
  Future<String> _generate(
    String key,
    GeminiModelInfo model, {
    required String systemInstruction,
    required String userText,
    required List<int> wav,
    int maxOutputTokens = 8192,
  }) async {
    while (true) {
      final mode = cache.thinkingFor(model.id);
      try {
        return await client.generateFromAudio(
          apiKey: key,
          model: model.id,
          systemInstruction: systemInstruction,
          userText: userText,
          wav: wav,
          minimalThinking: mode != GeminiThinking.none,
          thinkingLevel: mode.level,
          maxOutputTokens: maxOutputTokens,
        );
      } on CleanupFailure catch (f) {
        final next = _nextThinking(mode, f);
        if (next == null) rethrow;
        cache.rememberThinking(model.id, next);
      }
    }
  }

  /// The thinking mode to retry with after [f], or null when [f] is not about
  /// thinking.
  static GeminiThinking? _nextThinking(GeminiThinking current, CleanupFailure f) {
    if (current == GeminiThinking.none || f.kind != CleanupFailureKind.unknown) return null;
    final m = f.message.toLowerCase();
    if (!m.contains('think') && !m.contains('minimal')) return null;
    final levelRejected = m.contains('level') || m.contains('minimal');
    if (current == GeminiThinking.minimal && levelRejected) return GeminiThinking.low;
    return GeminiThinking.none;
  }

  /// Failures that mean "this model, not this audio": try the next model.
  static bool _tryNextModel(CleanupFailure f) => switch (f.kind) {
        CleanupFailureKind.server ||
        CleanupFailureKind.rateLimited ||
        CleanupFailureKind.dailyQuotaExceeded ||
        CleanupFailureKind.modelNotOnFreeTier ||
        CleanupFailureKind.modelUnavailable =>
          true,
        _ => false,
      };

  @override
  Future<String> process(CleanupRequest request) async {
    final key = await _key();
    final system = CleanupPrompt.systemFor(request);
    final userText = CleanupPrompt.userTextFor(request);
    final wav = WavEncoder.encode(request.pcm);

    var models = await availableModels();
    var chain = _chain(models);
    var refreshed = false;
    CleanupFailure? last;

    for (var i = 0; i < chain.length; i++) {
      final model = chain[i];
      Future<String> call() => _generate(key, model, systemInstruction: system, userText: userText, wav: wav);
      try {
        try {
          return CleanupPrompt.tidyFor(request, await call());
        } on CleanupFailure catch (f) {
          // Overloaded ("high demand"): one more try after a short pause.
          if (f.kind != CleanupFailureKind.server) rethrow;
          await Future<void>.delayed(overloadBackoff);
          return CleanupPrompt.tidyFor(request, await call());
        }
      } on CleanupFailure catch (f) {
        // Model renamed or retired since the list was cached: re-resolve once.
        if (!refreshed && (f.message.contains(' 404') || f.message.contains('NOT_FOUND'))) {
          refreshed = true;
          cache.invalidate();
          models = await availableModels(refresh: true);
          chain = _chain(models);
          i = -1;
          continue;
        }
        _remember(model, f);
        if (!_tryNextModel(f)) rethrow;
        last = f;
      }
    }
    throw last ?? const CleanupFailure(CleanupFailureKind.unknown, 'No Gemini model could be used.');
  }

  /// Remembers per-model dead ends so later requests skip the model.
  void _remember(GeminiModelInfo model, CleanupFailure f) {
    if (f.kind == CleanupFailureKind.modelNotOnFreeTier) cache.markFreeTierUnavailable(model.id);
    if (f.kind == CleanupFailureKind.modelUnavailable) cache.markUnavailable(model.id, f.message);
  }

  List<GeminiModelInfo> _chain(List<GeminiModelInfo> models) {
    final first = GeminiModelSelector.choose(models, preferred: preferredModel);
    if (first == null) {
      throw const CleanupFailure(
        CleanupFailureKind.server,
        'Google did not list any Gemini model that can transcribe audio for this key.',
      );
    }
    return GeminiModelSelector.chain(models, first);
  }

  @override
  Future<void> release() async {}
}
