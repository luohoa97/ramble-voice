// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import '../../audio/pcm.dart';
import '../cleanup_engine.dart';
import '../cleanup_prompt.dart';
import 'gemini_client.dart';
import 'gemini_models.dart';

/// Caches the resolved model so the list is fetched at most once a day.
class GeminiModelCache {
  GeminiModelCache({this.ttl = const Duration(hours: 24), DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _clock;
  List<GeminiModelInfo>? _models;
  DateTime? _fetchedAt;
  String? _forKey;

  List<GeminiModelInfo>? get(String key) {
    if (_models == null || _forKey != key || _fetchedAt == null) return null;
    return _clock().difference(_fetchedAt!) > ttl ? null : _models;
  }

  void put(String key, List<GeminiModelInfo> models) {
    _models = models;
    _forKey = key;
    _fetchedAt = _clock();
  }

  void invalidate() => _models = null;
}

/// Cloud cleanup with the user's own Gemini API key.
class GeminiEngine implements CleanupEngine {
  GeminiEngine({
    required this.apiKey,
    required this.client,
    GeminiModelCache? cache,
    this.preferredModel,
  }) : cache = cache ?? GeminiModelCache();

  /// Returns the key, or null when none is configured.
  final Future<String?> Function() apiKey;
  final GeminiClient client;
  final GeminiModelCache cache;

  /// A user-picked model id; ignored unless it is in the newest generation.
  final String? preferredModel;

  bool _thinkingConfigSupported = true;

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

  /// The newest Flash-Lite models available to this key.
  Future<List<GeminiModelInfo>> availableModels({bool refresh = false}) async {
    final key = await _key();
    final cached = refresh ? null : cache.get(key);
    if (cached != null) return cached;
    final models = GeminiModelSelector.liteModels(await client.listModels(key));
    final latest = GeminiModelSelector.latestGeneration(models);
    cache.put(key, latest);
    return latest;
  }

  Future<GeminiModelInfo> resolveModel({bool refresh = false}) async {
    final model = GeminiModelSelector.choose(await availableModels(refresh: refresh), preferred: preferredModel);
    if (model == null) {
      throw const CleanupFailure(
        CleanupFailureKind.server,
        'Google did not list any Gemini Flash-Lite model for this key.',
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
    final model = await resolveModel(refresh: true);
    await client.generateFromAudio(
      apiKey: await _key(),
      model: model.id,
      systemInstruction: 'Reply with the single word OK.',
      userText: 'Test.',
      wav: WavEncoder.encode(Uint8List(Pcm.bytesFor(const Duration(milliseconds: 500)))),
      minimalThinking: _thinkingConfigSupported,
      maxOutputTokens: 256,
    );
    return model.id;
  }

  @override
  Future<String> process(CleanupRequest request) async {
    final key = await _key();
    var model = await resolveModel();
    final system = request.mode == CleanupMode.clean
        ? CleanupPrompt.build(request.style)
        : CleanupPrompt.buildVerbatim(request.style);
    final wav = WavEncoder.encode(request.pcm);

    Future<String> call() => client.generateFromAudio(
          apiKey: key,
          model: model.id,
          systemInstruction: system,
          userText: CleanupPrompt.userTurn,
          wav: wav,
          minimalThinking: _thinkingConfigSupported,
        );

    try {
      return CleanupPrompt.tidyOutput(await call());
    } on CleanupFailure catch (f) {
      // Model renamed or retired since the cache was filled: re-resolve once.
      if (f.message.contains(' 404') || f.message.contains('NOT_FOUND')) {
        cache.invalidate();
        model = await resolveModel(refresh: true);
        return CleanupPrompt.tidyOutput(await call());
      }
      // Older or different models reject thinkingLevel: retry without it.
      if (_thinkingConfigSupported && f.kind == CleanupFailureKind.unknown && f.message.toLowerCase().contains('think')) {
        _thinkingConfigSupported = false;
        return CleanupPrompt.tidyOutput(await call());
      }
      rethrow;
    }
  }

  @override
  Future<void> release() async {}
}
