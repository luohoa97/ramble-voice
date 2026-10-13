// SPDX-License-Identifier: GPL-3.0-or-later

/// Picks Gemini models from Google's live model list: every Pro, Flash and
/// Flash-Lite text model that can take audio is offered, and the default is
/// the newest stable Flash. Nothing is hard-coded, so new generations appear
/// by themselves.
library;

/// Model family, best first.
enum GeminiFamily {
  pro('Pro'),
  flash('Flash'),
  flashLite('Flash-Lite');

  const GeminiFamily(this.label);

  /// The tier label shown in the UI.
  final String label;
}

/// How a model answered the health probe.
enum GeminiHealth { unknown, fast, slow, failed }

class GeminiModelInfo {
  const GeminiModelInfo({
    required this.id,
    required this.major,
    required this.minor,
    required this.preview,
    this.family = GeminiFamily.flashLite,
    this.alias = false,
    this.displayName,
    this.inputTokenLimit,
    this.freeTierUnavailable = false,
    this.unavailableReason,
    this.health = GeminiHealth.unknown,
    this.latency,
  });

  /// Model id without the `models/` prefix, e.g. `gemini-3.8-flash`.
  final String id;
  final int major;
  final int minor;
  final bool preview;
  final GeminiFamily family;

  /// A moving alias such as `gemini-flash-latest`.
  final bool alias;
  final String? displayName;
  final int? inputTokenLimit;

  /// Google answered `limit: 0` for this model: it has no free-tier quota for
  /// this key.
  final bool freeTierUnavailable;

  /// Why this key cannot use the model (retired for new users, rejects system
  /// instructions), or null. Learned from a failed request.
  final String? unavailableReason;

  /// The model cannot be used with this key, for either reason.
  bool get unavailable => freeTierUnavailable || unavailableReason != null;

  /// The last health probe result for this key.
  final GeminiHealth health;

  /// Probe round-trip time, when the probe succeeded.
  final Duration? latency;

  /// "Fast · 3.2 s", "Slow · 14 s", "Not responding", or null before a probe.
  String? get healthLabel {
    String secs(Duration d) {
      final s = d.inMilliseconds / 1000;
      return s < 10 ? '${s.toStringAsFixed(1)} s' : '${s.round()} s';
    }

    return switch (health) {
      GeminiHealth.unknown => null,
      GeminiHealth.fast => 'Fast · ${secs(latency ?? Duration.zero)}',
      GeminiHealth.slow => 'Slow · ${secs(latency ?? Duration.zero)}',
      GeminiHealth.failed => 'Not responding',
    };
  }

  /// `Pro`, `Flash` or `Flash-Lite`.
  String get tier => family.label;

  double get version => alias ? 1e6 : major + minor / 100;

  GeminiModelInfo copyWith({
    bool? freeTierUnavailable,
    String? unavailableReason,
    GeminiHealth? health,
    Duration? latency,
  }) => GeminiModelInfo(
    id: id,
    major: major,
    minor: minor,
    preview: preview,
    family: family,
    alias: alias,
    displayName: displayName,
    inputTokenLimit: inputTokenLimit,
    freeTierUnavailable: freeTierUnavailable ?? this.freeTierUnavailable,
    unavailableReason: unavailableReason ?? this.unavailableReason,
    health: health ?? this.health,
    latency: latency ?? this.latency,
  );

  @override
  String toString() => id;
}

abstract final class GeminiModelSelector {
  /// `gemini-<major>[.<minor>]-<family>`, optionally `-preview[-date]` or a
  /// `-NNN` revision.
  static final RegExp _pattern = RegExp(
    r'^gemini-(\d+)(?:\.(\d+))?-(flash-lite|flash|pro)(-preview(?:-[0-9-]+)?|-\d{3})?$',
  );

  /// `gemini-flash-latest` and friends.
  static final RegExp _aliasPattern = RegExp(
    r'^gemini-(flash-lite|flash|pro)-latest$',
  );

  /// Variants that are not text-from-audio models.
  static final RegExp _excluded = RegExp(
    r'tts|image|live|native-audio|embedding|omni|computer-use|robotics',
    caseSensitive: false,
  );

  static GeminiFamily _family(String s) => switch (s) {
    'pro' => GeminiFamily.pro,
    'flash' => GeminiFamily.flash,
    _ => GeminiFamily.flashLite,
  };

  /// Parses `GET /v1beta/models` entries (`{"name": "models/…", …}`) into every
  /// usable model, best first: Pro, then Flash, then Flash-Lite; inside a
  /// family the alias, then the newest version; stable before preview.
  static List<GeminiModelInfo> parse(List<Map<String, Object?>> models) {
    final out = <GeminiModelInfo>[];
    for (final m in models) {
      final name = (m['name'] as String? ?? '').replaceFirst('models/', '');
      final methods =
          (m['supportedGenerationMethods'] as List?)?.cast<String>() ??
          const [];
      if (!methods.contains('generateContent') || _excluded.hasMatch(name))
        continue;
      final displayName = m['displayName'] as String?;
      final limit = (m['inputTokenLimit'] as num?)?.toInt();
      final alias = _aliasPattern.firstMatch(name);
      if (alias != null) {
        out.add(
          GeminiModelInfo(
            id: name,
            major: 0,
            minor: 0,
            preview: false,
            family: _family(alias.group(1)!),
            alias: true,
            displayName: displayName,
            inputTokenLimit: limit,
          ),
        );
        continue;
      }
      final match = _pattern.firstMatch(name);
      if (match == null) continue;
      out.add(
        GeminiModelInfo(
          id: name,
          major: int.parse(match.group(1)!),
          minor: int.tryParse(match.group(2) ?? '') ?? 0,
          preview: (match.group(4) ?? '').startsWith('-preview'),
          family: _family(match.group(3)!),
          displayName: displayName,
          inputTokenLimit: limit,
        ),
      );
    }
    out.sort(_compare);
    return out;
  }

  static int _compare(GeminiModelInfo a, GeminiModelInfo b) {
    final f = a.family.index.compareTo(b.family.index);
    if (f != 0) return f;
    final v = b.version.compareTo(a.version);
    if (v != 0) return v;
    if (a.preview != b.preview) return a.preview ? 1 : -1;
    return a.id.length.compareTo(b.id.length);
  }

  static GeminiModelInfo? _newest(
    Iterable<GeminiModelInfo> sorted,
    GeminiFamily family, {
    bool stableOnly = true,
  }) {
    for (final m in sorted) {
      if (m.family == family &&
          !m.alias &&
          !m.unavailable &&
          !(stableOnly && m.preview))
        return m;
    }
    return null;
  }

  /// The default: the newest stable Flash, else the newest Flash preview, else
  /// Flash-Lite, else Pro, else whatever is listed first. Moving aliases and
  /// models known to lack free-tier quota are skipped unless nothing else is
  /// left.
  static GeminiModelInfo? defaultModel(List<GeminiModelInfo> sorted) {
    if (sorted.isEmpty) return null;
    // The newest Flash is the default. If it is known to lack quota, go to
    // Flash-Lite rather than to an older Flash.
    for (final stableOnly in [true, false]) {
      for (final m in sorted) {
        if (m.family != GeminiFamily.flash ||
            m.alias ||
            (stableOnly && m.preview))
          continue;
        if (!m.unavailable) return m;
        break;
      }
    }
    return _newest(sorted, GeminiFamily.flashLite) ??
        _newest(sorted, GeminiFamily.flashLite, stableOnly: false) ??
        _newest(sorted, GeminiFamily.pro) ??
        _newest(sorted, GeminiFamily.pro, stableOnly: false) ??
        sorted.first;
  }

  /// The model to use: the user's pick if it is listed, else [defaultModel].
  static GeminiModelInfo? choose(
    List<GeminiModelInfo> sorted, {
    String? preferred,
  }) {
    if (preferred != null) {
      for (final m in sorted) {
        if (m.id == preferred) return m;
      }
    }
    return defaultModel(sorted);
  }

  /// The stable Flash models worth probing and trying, newest first.
  static List<GeminiModelInfo> stableFlash(List<GeminiModelInfo> sorted) => [
    for (final m in sorted)
      if (m.family == GeminiFamily.flash &&
          !m.alias &&
          !m.preview &&
          !m.unavailable)
        m,
  ];

  /// The newest stable Flash-Lite (or preview if there is no stable one).
  static GeminiModelInfo? liteBackup(List<GeminiModelInfo> sorted) =>
      _newest(sorted, GeminiFamily.flashLite) ??
      _newest(sorted, GeminiFamily.flashLite, stableOnly: false);

  /// Automatic order once a health probe has run: Flash models that answered
  /// quickly, newest to oldest; then Flash models that answered slowly; then
  /// the newest Flash-Lite. Models that did not answer are left out.
  /// Null when nothing was probed yet.
  static List<GeminiModelInfo>? chainByHealth(List<GeminiModelInfo> sorted) {
    final flash = stableFlash(sorted);
    if (flash.every((m) => m.health == GeminiHealth.unknown)) return null;
    final out = [
      ...flash.where((m) => m.health == GeminiHealth.fast),
      ...flash.where((m) => m.health == GeminiHealth.slow),
    ];
    final backup = liteBackup(sorted);
    if (backup != null && backup.health != GeminiHealth.failed) out.add(backup);
    return out.isEmpty && backup != null ? [backup] : out;
  }

  /// Models to try in order: [first], then the newest stable Flash-Lite as the
  /// fast, cheap backup. The pipeline's on-device fallback comes after this.
  static List<GeminiModelInfo> chain(
    List<GeminiModelInfo> sorted,
    GeminiModelInfo first,
  ) {
    final start = first.unavailable ? (defaultModel(sorted) ?? first) : first;
    // Then up to two older stable models of the same family and generation,
    // so a stalled newest model (a busy 3.8 Flash) falls back to 3.7, 3.6;
    // never to an older generation.
    final siblings = sorted
        .where(
          (m) =>
              start.family != GeminiFamily.flashLite &&
              m.family == start.family &&
              m.major == start.major &&
              m.id != start.id &&
              !m.alias &&
              !m.preview &&
              !m.unavailable,
        )
        .take(2);
    final backup =
        _newest(sorted, GeminiFamily.flashLite) ??
        _newest(sorted, GeminiFamily.flashLite, stableOnly: false);
    final out = <GeminiModelInfo>[start, ...siblings];
    if (backup != null && out.every((m) => m.id != backup.id)) out.add(backup);
    return out;
  }
}
