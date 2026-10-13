// SPDX-License-Identifier: GPL-3.0-or-later

/// On-device Gemma 4 variants. Weights are downloaded at runtime from
/// Hugging Face (ungated, Apache-2.0) and are never part of this repository.
library;

class GemmaVariant {
  const GemmaVariant({
    required this.id,
    required this.label,
    required this.repo,
    required this.file,
    required this.sizeBytes,
    required this.sha256,
    required this.recommendedRamGb,
    required this.summary,
  });

  final String id;
  final String label;

  /// Hugging Face repo, e.g. `litert-community/gemma-4-E4B-it-litert-lm`.
  final String repo;
  final String file;
  final int sizeBytes;

  /// LFS sha256 published by Hugging Face for [file].
  final String sha256;

  /// Free RAM we recommend. Google publishes no official minimum; these are
  /// estimates from the model card's measured peak memory plus headroom.
  final int recommendedRamGb;
  final String summary;

  Uri get downloadUrl =>
      Uri.parse('https://huggingface.co/$repo/resolve/main/$file');
  Uri get modelCardUrl => Uri.parse('https://huggingface.co/$repo');

  String get sizeLabel => '${(sizeBytes / 1e9).toStringAsFixed(1)} GB';
}

abstract final class ModelCatalog {
  static const e4b = GemmaVariant(
    id: 'gemma-4-e4b',
    label: 'Gemma 4 E4B',
    repo: 'litert-community/gemma-4-E4B-it-litert-lm',
    file: 'gemma-4-E4B-it.litertlm',
    sizeBytes: 3659530240,
    sha256: '0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0',
    recommendedRamGb: 6,
    summary: 'Best quality. Recommended for flagship phones and desktops.',
  );

  static const e2b = GemmaVariant(
    id: 'gemma-4-e2b',
    label: 'Gemma 4 E2B',
    repo: 'litert-community/gemma-4-E2B-it-litert-lm',
    file: 'gemma-4-E2B-it.litertlm',
    sizeBytes: 2588147712,
    sha256: '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
    recommendedRamGb: 4,
    summary: 'Lighter and faster. For devices with less memory.',
  );

  static const all = [e4b, e2b];
  static const defaultVariant = e4b;

  static GemmaVariant? byId(String? id) {
    for (final v in all) {
      if (v.id == id) return v;
    }
    return null;
  }

  /// Gemma 4 accepts at most 30 s of audio per request (Google model card).
  /// We chunk below that to leave room for a pause search.
  static const maxAudioPerRequest = Duration(seconds: 28);

  static const licenseName = 'Apache License 2.0';
  static final licenseUrl = Uri.parse('https://ai.google.dev/gemma/apache_2');
  static const attribution =
      'Gemma is provided by Google under the Apache License 2.0. '
      'Model weights are downloaded from Hugging Face (litert-community) and are '
      'not covered by Ramble Voice\'s GPL-3.0 license.';
}
