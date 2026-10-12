// SPDX-License-Identifier: GPL-3.0-or-later

/// Picks the newest Gemini "Flash-Lite" model from Google's live model list,
/// so the app never hard-codes (and never falls back to) an old model.
library;

class GeminiModelInfo {
  const GeminiModelInfo({
    required this.id,
    required this.major,
    required this.minor,
    required this.preview,
    this.displayName,
    this.inputTokenLimit,
  });

  /// Model id without the `models/` prefix, e.g. `gemini-3.5-flash-lite`.
  final String id;
  final int major;
  final int minor;
  final bool preview;
  final String? displayName;
  final int? inputTokenLimit;

  double get version => major + minor / 100;

  @override
  String toString() => id;
}

abstract final class GeminiModelSelector {
  /// Matches `gemini-<major>[.<minor>]-flash-lite`, optionally followed by
  /// `-preview` and a date suffix, or a `-NNN` revision. Excludes variants
  /// for other modalities (tts, image, live, audio-dialog, etc).
  static final RegExp _pattern = RegExp(
    r'^gemini-(\d+)(?:\.(\d+))?-flash-lite(-preview(?:-[0-9-]+)?|-\d{3})?$',
  );

  /// Parses `GET /v1beta/models` entries (`{"name": "models/…", …}`).
  static List<GeminiModelInfo> liteModels(List<Map<String, Object?>> models) {
    final out = <GeminiModelInfo>[];
    for (final m in models) {
      final name = (m['name'] as String? ?? '').replaceFirst('models/', '');
      final methods = (m['supportedGenerationMethods'] as List?)?.cast<String>() ?? const [];
      if (!methods.contains('generateContent')) continue;
      final match = _pattern.firstMatch(name);
      if (match == null) continue;
      out.add(GeminiModelInfo(
        id: name,
        major: int.parse(match.group(1)!),
        minor: int.tryParse(match.group(2) ?? '') ?? 0,
        preview: (match.group(3) ?? '').startsWith('-preview'),
        displayName: m['displayName'] as String?,
        inputTokenLimit: (m['inputTokenLimit'] as num?)?.toInt(),
      ));
    }
    out.sort(_compare);
    return out;
  }

  /// Newest first: higher version, then stable before preview, then the
  /// plain alias before pinned revisions.
  static int _compare(GeminiModelInfo a, GeminiModelInfo b) {
    final v = b.version.compareTo(a.version);
    if (v != 0) return v;
    if (a.preview != b.preview) return a.preview ? 1 : -1;
    return a.id.length.compareTo(b.id.length);
  }

  /// Only models from the newest generation are offered, so old models are
  /// never used even as a fallback.
  static List<GeminiModelInfo> latestGeneration(List<GeminiModelInfo> sorted) {
    if (sorted.isEmpty) return const [];
    final newest = sorted.first.version;
    return sorted.where((m) => m.version == newest).toList();
  }

  /// The model to use, honouring a user pick if it is still in the newest
  /// generation.
  static GeminiModelInfo? choose(List<GeminiModelInfo> sorted, {String? preferred}) {
    final latest = latestGeneration(sorted);
    if (latest.isEmpty) return null;
    if (preferred != null) {
      for (final m in latest) {
        if (m.id == preferred) return m;
      }
    }
    return latest.first;
  }
}
