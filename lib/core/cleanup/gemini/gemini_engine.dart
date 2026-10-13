// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
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
  medium('medium'),
  high('high'),

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
  final _slowUntil = <String, DateTime>{};
  final _health = <String, ({GeminiHealth health, Duration? latency})>{};
  DateTime? _probedAt;

  /// The probe in flight, if any. Awaiting it is safe: it never throws.
  Future<void>? probing;

  /// How long a probe result is trusted.
  static const probeTtl = Duration(hours: 6);

  List<GeminiModelInfo>? get(String key) {
    if (_models == null || _forKey != key || _fetchedAt == null) return null;
    return _clock().difference(_fetchedAt!) > ttl ? null : annotate(_models!);
  }

  void put(String key, List<GeminiModelInfo> models) {
    if (_forKey != key) {
      _thinking.clear();
      _noFreeTier.clear();
      _unavailable.clear();
      _health.clear();
      _probedAt = null;
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

  /// A model that just timed out is not tried first again for [period].
  void markSlow(String modelId, {Duration period = const Duration(minutes: 10)}) =>
      _slowUntil[modelId] = _clock().add(period);

  bool isSlow(String modelId) {
    final until = _slowUntil[modelId];
    return until != null && _clock().isBefore(until);
  }

  /// Whether a health probe is due for the current list (never probed, or
  /// older than [probeTtl]) and none is running.
  bool probeDue() {
    if (probing != null) return false;
    final at = _probedAt;
    return at == null || _clock().difference(at) >= probeTtl;
  }

  /// Marks the probe as run now, so it is not started twice.
  void probeStarted() => _probedAt = _clock();

  void recordHealth(String modelId, GeminiHealth health, Duration? latency) =>
      _health[modelId] = (health: health, latency: latency);

  GeminiHealth healthOf(String modelId) => _health[modelId]?.health ?? GeminiHealth.unknown;

  /// [models] with [GeminiModelInfo.freeTierUnavailable] and
  /// [GeminiModelInfo.unavailableReason] applied.
  List<GeminiModelInfo> annotate(List<GeminiModelInfo> models) => [
        for (final m in models)
          if (_noFreeTier.contains(m.id) || _unavailable.containsKey(m.id) || _health.containsKey(m.id))
            m.copyWith(
              freeTierUnavailable: _noFreeTier.contains(m.id) ? true : null,
              unavailableReason: _unavailable[m.id],
              health: _health[m.id]?.health,
              latency: _health[m.id]?.latency,
            )
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
    this.healthProbe = false,
    this.probeTimeout = const Duration(seconds: 15),
    this.fastLatency = const Duration(seconds: 10),
    this.pickedModelTimeout = const Duration(seconds: 20),
    this.thinkOnCleanup = false,
  }) : cache = cache ?? GeminiModelCache();

  /// Returns the key, or null when none is configured.
  final Future<String?> Function() apiKey;
  final GeminiClient client;
  final GeminiModelCache cache;

  /// A user-picked model id from [availableModels]; unknown ids are ignored.
  final String? preferredModel;

  /// Wait before the single retry after a 503 "high demand".
  final Duration overloadBackoff;

  /// Probe the newest Flash models in the background when the model list
  /// resolves (at most every [GeminiModelCache.probeTtl]) and order the
  /// automatic chain by how fast they answered. Off in tests that count
  /// requests.
  final bool healthProbe;

  /// Give up on one probe request after this long: the model counts as not
  /// responding.
  final Duration probeTimeout;

  /// A probe answered within this is "fast".
  final Duration fastLatency;

  /// Request timeout for a model the user picked when the probe found it slow
  /// or not responding, so a bad pick falls back quickly.
  final Duration pickedModelTimeout;

  /// Lets the model reason ("high" thinking) before writing the
  /// cleaned text: better at intent, lists, quoting and commands, a little
  /// slower. One request either way: the model hears the audio and reasons
  /// about it together.
  final bool thinkOnCleanup;

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
    if (cached != null) {
      _probeIfDue(key, cached);
      return cached;
    }
    final models = GeminiModelSelector.parse(await client.listModels(key));
    cache.put(key, models);
    final annotated = cache.annotate(models);
    _probeIfDue(key, annotated);
    return annotated;
  }

  void _probeIfDue(String key, List<GeminiModelInfo> models) {
    if (!healthProbe || !cache.probeDue()) return;
    cache.probing = probeHealth(models: models).whenComplete(() => cache.probing = null);
  }

  /// Sends a tiny request to the four newest stable Flash models (and the
  /// user's pick) in parallel and records how fast each answered. Never
  /// throws.
  Future<void> probeHealth({List<GeminiModelInfo>? models}) async {
    try {
      final key = await _key();
      final list = models ?? await availableModels();
      cache.probeStarted();
      final targets = GeminiModelSelector.stableFlash(list).take(4).toList();
      final picked = preferredModel;
      if (picked != null && targets.every((m) => m.id != picked)) {
        for (final m in list) {
          if (m.id == picked && !m.unavailable) targets.add(m);
        }
      }
      final wav = WavEncoder.encode(Uint8List(Pcm.bytesFor(const Duration(milliseconds: 500))));
      await Future.wait([for (final m in targets) _probeOne(key, m, wav)]);
    } catch (_) {
      // A probe is best effort.
    }
  }

  Future<void> _probeOne(String key, GeminiModelInfo model, Uint8List wav) async {
    final watch = Stopwatch()..start();
    try {
      await _generate(
        key,
        model,
        systemInstruction: 'Reply with the single word OK.',
        userText: 'Test.',
        wav: wav,
        maxOutputTokens: 16,
        timeout: probeTimeout,
      );
      watch.stop();
      final latency = watch.elapsed;
      cache.recordHealth(model.id, latency < fastLatency ? GeminiHealth.fast : GeminiHealth.slow, latency);
    } on CleanupFailure catch (f) {
      _remember(model, f);
      cache.recordHealth(model.id, GeminiHealth.failed, null);
    } catch (_) {
      cache.recordHealth(model.id, GeminiHealth.failed, null);
    }
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
    Duration? timeout,
    bool think = false,
  }) async {
    var thinkRejected = 0;
    while (true) {
      var mode = cache.thinkingFor(model.id);
      // A little reasoning for the cleanup pass (intent, lists, quoting),
      // unless the model refused thinking levels.
      if (think && mode == GeminiThinking.minimal) {
        mode = _thinkLadder[math.min(thinkRejected, _thinkLadder.length - 1)];
      }
      try {
        return await client.generateFromAudio(
          apiKey: key,
          model: model.id,
          systemInstruction: systemInstruction,
          userText: userText,
          wav: wav,
          minimalThinking: mode != GeminiThinking.none,
          thinkingLevel: mode.level,
          // Thinking tokens count against the output limit.
          maxOutputTokens: _thinkLadder.contains(mode) ? maxOutputTokens * 4 : maxOutputTokens,
          timeout: timeout ?? requestTimeout(wav.length),
        );
      } on CleanupFailure catch (f) {
        final next = _nextThinking(mode, f);
        if (next == null) rethrow;
        // A level refused: step down (high, medium, low) before giving up on thinking.
        if (think && thinkRejected < _thinkLadder.length - 1 && _thinkLadder.contains(mode)) {
          thinkRejected++;
          continue;
        }
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

  static const _thinkLadder = [GeminiThinking.high, GeminiThinking.medium, GeminiThinking.low];

  /// Base wait plus the clip's own length: long clips legitimately take longer.
  static Duration requestTimeout(int wavBytes) =>
      const Duration(seconds: 45) + Pcm.durationOf(wavBytes);

  /// Failures that mean "this model, not this audio": try the next model.
  static bool _tryNextModel(CleanupFailure f) => switch (f.kind) {
        CleanupFailureKind.server ||
        CleanupFailureKind.timedOut ||
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
    final wav = WavEncoder.encode(request.pcm);
    return _runChain(
      key,
      wav,
      CleanupPrompt.systemFor(request),
      CleanupPrompt.userTextFor(request),
      (raw) => CleanupPrompt.tidyFor(request, raw),
      think: thinkOnCleanup && request.mode != CleanupMode.verbatim,
    );
  }

  /// Sends one prompt down the model chain, falling through to the next
  /// model on model-level failures.
  Future<String> _runChain(
    String key,
    Uint8List wav,
    String system,
    String userText,
    String Function(String raw) tidy, {
    bool think = false,
  }) async {
    var models = await availableModels();
    var chain = _chain(models);
    var refreshed = false;
    CleanupFailure? last;

    for (var i = 0; i < chain.length; i++) {
      final model = chain[i];
      final timeout = _timeoutFor(model, wav.length);
      Future<String> call() =>
          _generate(key, model, systemInstruction: system, userText: userText, wav: wav, timeout: timeout, think: think);
      try {
        try {
          return tidy(await call());
        } on CleanupFailure catch (f) {
          // Overloaded ("high demand"): one more try after a short pause.
          if (f.kind != CleanupFailureKind.server) rethrow;
          await Future<void>.delayed(overloadBackoff);
          return tidy(await call());
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

  /// The user's own pick keeps the first place, but when the probe found it
  /// slow or not responding it only gets [pickedModelTimeout].
  Duration _timeoutFor(GeminiModelInfo model, int wavBytes) {
    final normal = requestTimeout(wavBytes);
    final picked = preferredModel == model.id;
    final health = cache.healthOf(model.id);
    if (picked && (health == GeminiHealth.slow || health == GeminiHealth.failed) && pickedModelTimeout < normal) {
      return pickedModelTimeout;
    }
    return normal;
  }

  /// Remembers per-model dead ends so later requests skip the model.
  void _remember(GeminiModelInfo model, CleanupFailure f) {
    if (f.kind == CleanupFailureKind.modelNotOnFreeTier) cache.markFreeTierUnavailable(model.id);
    if (f.kind == CleanupFailureKind.modelUnavailable) cache.markUnavailable(model.id, f.message);
    if (f.kind == CleanupFailureKind.timedOut || f.kind == CleanupFailureKind.server) cache.markSlow(model.id);
  }

  List<GeminiModelInfo> _chain(List<GeminiModelInfo> models) {
    final first = GeminiModelSelector.choose(models, preferred: preferredModel);
    if (first == null) {
      throw const CleanupFailure(
        CleanupFailureKind.server,
        'Google did not list any Gemini model that can transcribe audio for this key.',
      );
    }
    final picked = preferredModel != null && models.any((m) => m.id == preferredModel && !m.unavailable);
    // Automatic mode with probe results: healthy Flash models first.
    final byHealth = picked ? null : GeminiModelSelector.chainByHealth(models);
    final chain = byHealth != null && byHealth.isNotEmpty ? byHealth : GeminiModelSelector.chain(models, first);
    // Models that just stalled go last so the next dictation doesn't wait.
    return [...chain.where((m) => !cache.isSlow(m.id)), ...chain.where((m) => cache.isSlow(m.id))];
  }

  @override
  Future<void> release() async {}
}
