// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

import '../../audio/pcm.dart';
import '../../models/model_catalog.dart';
import '../cleanup_engine.dart';
import '../cleanup_prompt.dart';

/// On-device cleanup with Gemma 4 through flutter_edge_ai (LiteRT-LM).
/// One fresh session per request, so no audio or text carries over between
/// dictations.
class GemmaEngine implements CleanupEngine, WarmableEngine {
  GemmaEngine({required this.variant, required this.modelPath, this.think = false, this.npuReady});

  /// Whether Qualcomm's NPU runtime is downloaded (NPU variants need it).
  final Future<bool> Function()? npuReady;

  /// Gemma 4 reasons before answering (its thinking mode): better at intent,
  /// lists and quoting, slower. The reasoning is stripped from the result.
  final bool think;

  final GemmaVariant variant;

  /// Returns the verified model file path, or null if not downloaded.
  final Future<String?> Function() modelPath;

  static bool _initialized = false;
  static String? _registeredPath;
  InferenceModel? _model;
  Future<InferenceModel>? _loading;

  @override
  EngineKind get kind => EngineKind.onDevice;

  @override
  Duration get maxAudioPerRequest => ModelCatalog.maxAudioPerRequest;

  /// Backend actually in use after loading ("GPU" or "CPU"). LiteRT-LM falls
  /// back to CPU silently, so the UI shows this.
  String? get activeBackend => switch (_model?.activeBackend) {
        PreferredBackend.gpu => 'GPU',
        PreferredBackend.cpu => 'CPU',
        PreferredBackend.npu => 'NPU',
        null => null,
      };

  @override
  Future<EngineReadiness> readiness() async {
    final path = await modelPath();
    if (path == null || !await File(path).exists()) {
      return EngineNotReady(
        CleanupFailureKind.modelNotDownloaded,
        '${variant.label} is not downloaded yet. Download it in Settings.',
      );
    }
    if (variant.usesNpu && !(await npuReady?.call() ?? false)) {
      return const EngineNotReady(
        CleanupFailureKind.modelNotDownloaded,
        'The NPU model needs the Qualcomm NPU runtime. Download it in Settings.',
      );
    }
    return EngineReady(detail: activeBackend == null ? variant.label : '${variant.label} · $activeBackend');
  }

  /// Loads the model while the person speaks, so processing starts at once.
  @override
  Future<void> warmUp() async {
    try {
      await _ensureModel();
    } catch (_) {
      // The real request reports the failure.
    }
  }

  Future<InferenceModel> _ensureModel() async {
    final existing = _model;
    if (existing != null) return existing;
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<InferenceModel> _load() async {
    final path = await modelPath();
    if (path == null || !await File(path).exists()) {
      throw CleanupFailure(
        CleanupFailureKind.modelNotDownloaded,
        '${variant.label} is not downloaded yet. Download it in Settings.',
      );
    }
    if (!_initialized) {
      await FlutterEdgeAi.initialize(inferenceEngines: [LiteRtLmEngine()]);
      _initialized = true;
    }
    if (_registeredPath != path) {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      ).fromFile(path).install();
      _registeredPath = path;
    }
    try {
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 4096,
        supportAudio: true,
        preferredBackend: variant.usesNpu ? PreferredBackend.npu : PreferredBackend.gpu,
        // Gemma 4's audio encoder only runs on the CPU ("Audio backend
        // constraint mismatch. Model requires one of [cpu]"); asking for the
        // GPU failed engine creation on every backend.
        preferredAudioBackend: PreferredBackend.cpu,
      );
      _model = model;
      return model;
    } catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<String> process(CleanupRequest request) async {
    final model = await _ensureModel();
    final system = CleanupPrompt.systemFor(request);
    InferenceModelSession? session;
    try {
      session = await model.createSession(
        temperature: 0.2,
        topK: 40,
        enableAudioModality: true,
        systemInstruction: system,
        enableThinking: think,
        maxOutputTokens: think ? 4096 : 2048,
      );
      await session.addQueryChunk(Message.withAudio(
        text: CleanupPrompt.userTextFor(request),
        audioBytes: WavEncoder.encode(request.pcm),
        isUser: true,
      ));
      final raw = ModelThinkingFilter.cleanResponse(
        await session.getResponse(),
        enableThinking: think,
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      );
      return CleanupPrompt.tidyFor(request, raw);
    } on CleanupFailure {
      rethrow;
    } catch (e) {
      throw _mapError(e);
    } finally {
      await session?.close();
    }
  }

  CleanupFailure _mapError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('out of memory') || s.contains('oom') || s.contains('bad_alloc') || s.contains('memory')) {
      return CleanupFailure(
        CleanupFailureKind.outOfMemory,
        'Not enough memory to run ${variant.label}. Close other apps or switch to Gemma 4 E2B.',
        cause: e,
      );
    }
    return CleanupFailure(CleanupFailureKind.unknown, 'On-device model error: $e', cause: e);
  }

  @override
  Future<void> release() async {
    final model = _model;
    _model = null;
    await model?.close();
  }
}
