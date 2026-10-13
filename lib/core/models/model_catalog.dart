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
    this.npuSoc,
    this.experimental = false,
  });

  /// Set for a build compiled for one chip's NPU (Qualcomm `SM8750`, ...):
  /// offered only on that chip, and run on its NPU with Qualcomm's runtime.
  final String? npuSoc;

  /// Works, but not verified on a phone by us: shown with a label.
  final bool experimental;

  bool get usesNpu => npuSoc != null;

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

  Uri get downloadUrl => Uri.parse('https://huggingface.co/$repo/resolve/main/$file');
  Uri get modelCardUrl => Uri.parse('https://huggingface.co/$repo');

  String get sizeLabel => '${(sizeBytes / 1e9).toStringAsFixed(1)} GB';
}

/// What the phone offers for on-device models (Android; null on desktops).
class DeviceInfo {
  const DeviceInfo({this.soc, this.ramBytes = 0, this.fastRpc = false, this.npuRuntime = false});

  factory DeviceInfo.fromMap(Map<Object?, Object?> m) => DeviceInfo(
        soc: m['soc'] as String?,
        ramBytes: (m['ramBytes'] as num?)?.toInt() ?? 0,
        fastRpc: m['fastRpc'] as bool? ?? false,
        npuRuntime: m['npuRuntime'] as bool? ?? false,
      );

  /// `Build.SOC_MODEL`, e.g. `SM8650`.
  final String? soc;
  final int ramBytes;

  /// Qualcomm's NPU driver is present.
  final bool fastRpc;

  /// Qualcomm's QNN runtime has been downloaded.
  final bool npuRuntime;

  /// Total memory in GB, rounded (a "12 GB" phone reports a little less).
  int get ramGb => (ramBytes / (1 << 30)).round();
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

  /// The 12B model: much more capable, text, vision and audio. Google lists
  /// it for desktops (about 7.8 GB of GPU memory); phones need 12 GB+ RAM.
  static const e12b = GemmaVariant(
    id: 'gemma-4-12b',
    label: 'Gemma 4 12B',
    repo: 'litert-community/gemma-4-12B-it-litert-lm',
    file: 'gemma-4-12B-it.litertlm',
    sizeBytes: 6883278368,
    sha256: '58fd31b778ca2c21c80d634fb34fc5a89d11d563a38dfd3cbf1b40dbf252a8b6',
    recommendedRamGb: 12,
    summary: 'Most accurate. For desktops and phones with 12 GB of memory or more.',
    experimental: true,
  );

  /// E2B compiled for the Snapdragon 8 Elite (SM8750) NPU.
  static const e2bNpuSm8750 = GemmaVariant(
    id: 'gemma-4-e2b-npu-sm8750',
    label: 'Gemma 4 E2B · NPU',
    repo: 'litert-community/gemma-4-E2B-it-litert-lm',
    file: 'gemma-4-E2B-it_qualcomm_sm8750.litertlm',
    sizeBytes: 3016294400,
    sha256: '41dd675fbe735b6029012b5576a5716bac614fd8156de0128db4c9dff3cebd4e',
    recommendedRamGb: 6,
    summary: 'Runs on the Snapdragon 8 Elite NPU: fast and cool. Needs the Qualcomm runtime.',
    npuSoc: 'SM8750',
    experimental: true,
  );

  static const all = [e4b, e2b, e12b, e2bNpuSm8750];

  /// The variants this device can run: NPU builds only on their chip (with
  /// Qualcomm FastRPC), big models only with enough memory. Desktops (no
  /// [device]) get every non-NPU variant.
  static List<GemmaVariant> availableOn(DeviceInfo? device) => [
        for (final v in all)
          if (device == null
              ? !v.usesNpu
              : v.usesNpu
                  ? device.fastRpc && device.soc?.toUpperCase() == v.npuSoc
                  : device.ramGb >= (v.recommendedRamGb >= 12 ? v.recommendedRamGb - 1 : 0))
            v,
      ];
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
