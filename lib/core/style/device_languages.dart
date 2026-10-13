// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'languages.dart';

/// Most languages preselected from the device.
const _maxDeviceLanguages = 3;

/// Language codes from locale strings like `en_AU.UTF-8`, `zh-Hans-CN` or
/// `de:fr` (the `LANGUAGE` list), known languages only, in order.
List<String> languagesFromLocales(Iterable<String> locales) {
  final codes = <String>[];
  for (final raw in locales) {
    for (final part in raw.split(':')) {
      final tag = part.split('.').first.split('@').first.trim();
      if (tag.isEmpty || tag == 'C' || tag == 'POSIX') continue;
      codes.add(tag);
    }
  }
  return Languages.normaliseList(codes).take(_maxDeviceLanguages).toList();
}

/// The device's language(s): Flutter's locale list (Android), then
/// `LANGUAGE`/`LC_ALL`/`LANG` (Linux), then `Platform.localeName`. Empty when
/// nothing usable is found, which means "detect any language".
List<String> detectDeviceLanguages() {
  final locales = <String>[];
  try {
    locales.addAll([
      for (final l in PlatformDispatcher.instance.locales) l.toLanguageTag(),
    ]);
  } catch (_) {}
  if (Platform.isLinux) {
    final env = Platform.environment;
    for (final k in ['LANGUAGE', 'LC_ALL', 'LC_MESSAGES', 'LANG']) {
      final v = env[k];
      if (v != null && v.isNotEmpty) locales.add(v);
    }
  }
  try {
    locales.add(Platform.localeName);
  } catch (_) {}
  return languagesFromLocales(locales);
}
