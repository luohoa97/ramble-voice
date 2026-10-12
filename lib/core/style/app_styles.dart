// SPDX-License-Identifier: GPL-3.0-or-later

/// Per-app tone. The keyboard knows which app it types into; mail apps get
/// Professional, chat apps get Texting, note apps get Notes.
library;

import '../settings/app_settings.dart';
import 'style_profile.dart';

/// Built-in defaults, matched by package-name prefix. First match wins.
const Map<String, StylePreset> kBuiltInAppStyles = {
  'com.google.android.gm': StylePreset.professional,
  'com.microsoft.office.outlook': StylePreset.professional,
  'com.fastmail': StylePreset.professional,
  'ch.protonmail': StylePreset.professional,
  'com.whatsapp': StylePreset.texting,
  'org.telegram': StylePreset.texting,
  'org.thoughtcrime.securesms': StylePreset.texting,
  'com.discord': StylePreset.texting,
  'com.facebook.orca': StylePreset.texting,
  'com.instagram.android': StylePreset.texting,
  'com.snapchat': StylePreset.texting,
  'com.google.android.apps.messaging': StylePreset.texting,
  'com.slack': StylePreset.texting,
  'com.google.android.keep': StylePreset.notes,
  'md.obsidian': StylePreset.notes,
  'com.notion.id': StylePreset.notes,
  'com.evernote': StylePreset.notes,
  'com.samsung.android.app.notes': StylePreset.notes,
};

/// The built-in tone for [packageName], or null when there is none.
StylePreset? builtInStyleFor(String? packageName) {
  if (packageName == null || packageName.isEmpty) return null;
  // Package names are case-sensitive on Android, but a few apps ship with
  // capitals (com.Slack), so match without case.
  final pkg = packageName.toLowerCase();
  for (final e in kBuiltInAppStyles.entries) {
    if (pkg == e.key || pkg.startsWith('${e.key}.')) return e.value;
  }
  return null;
}

/// Tone for [packageName]: the user's override, else the built-in default for
/// that app, else [global]. [overrides] matches the package exactly.
StylePreset styleFor(
  String? packageName, {
  StylePreset global = StylePreset.casual,
  Map<String, StylePreset> overrides = const {},
}) {
  if (packageName != null) {
    final own = overrides[packageName];
    if (own != null) return own;
  }
  return builtInStyleFor(packageName) ?? global;
}

extension AppStyles on AppSettings {
  /// The tone to use when dictating into [packageName].
  StylePreset styleForApp(String? packageName) =>
      styleFor(packageName, global: style.preset, overrides: appStyles);

  /// [style] with the tone resolved for [packageName].
  StyleProfile styleProfileFor(String? packageName) => effectiveStyle.copyWith(preset: styleForApp(packageName));
}
