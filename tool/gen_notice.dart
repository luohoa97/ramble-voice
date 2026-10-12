// SPDX-License-Identifier: GPL-3.0-or-later
//
// Generates the NOTICE file. Reads pubspec.lock and each hosted package's
// LICENSE from the pub cache, and prints the result to stdout.
//
//   tool/fl dart run tool/gen_notice.dart > NOTICE
import 'dart:io';

class Pkg {
  Pkg(this.name, this.version, this.dependency);
  final String name;
  final String version;
  final String dependency;
}

List<Pkg> parseLock(String text) {
  final out = <Pkg>[];
  String? name;
  String? dep;
  String? source;
  for (final line in text.split('\n')) {
    final top = RegExp(r'^  ([A-Za-z0-9_]+):\s*$').firstMatch(line);
    if (top != null) {
      name = top.group(1);
      dep = null;
      source = null;
      continue;
    }
    final d = RegExp(r'^    dependency:\s*"?([^"]+)"?\s*$').firstMatch(line);
    if (d != null) dep = d.group(1);
    final s = RegExp(r'^    source:\s*(\S+)').firstMatch(line);
    if (s != null) source = s.group(1);
    final v = RegExp(r'^    version:\s*"?([^"\s]+)"?').firstMatch(line);
    if (v != null && name != null && source == 'hosted') {
      out.add(Pkg(name, v.group(1)!, dep ?? 'transitive'));
    }
  }
  return out;
}

String detectLicense(String text) {
  final t = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  bool has(String s) => t.contains(s);
  if (has('apache license') && has('version 2.0')) return 'Apache-2.0';
  if (has('mozilla public license') && has('2.0')) return 'MPL-2.0';
  if (has('gnu lesser general public license')) return 'LGPL';
  if (has('gnu general public license')) return 'GPL';
  if (has('permission is hereby granted, free of charge')) return 'MIT';
  if (has('redistribution and use in source and binary forms')) {
    if (has('neither the name') || has('the name of')) return 'BSD-3-Clause';
    return 'BSD-2-Clause';
  }
  if (has('permission to use, copy, modify, and/or distribute') ||
      has('permission to use, copy, modify, and distribute')) {
    return 'ISC';
  }
  if (has('the unlicense') || has('this is free and unencumbered')) {
    return 'Unlicense';
  }
  if (has('zlib')) return 'Zlib';
  return 'UNKNOWN (see package LICENSE)';
}

String pubCache() {
  final env = Platform.environment;
  if (env['PUB_CACHE'] != null) return env['PUB_CACHE']!;
  return '${env['HOME']}/.pub-cache';
}

void main() {
  final lock = File('pubspec.lock');
  if (!lock.existsSync()) {
    stderr.writeln('Run from the repository root (pubspec.lock not found).');
    exit(1);
  }
  final pkgs = parseLock(lock.readAsStringSync())
    ..sort((a, b) => a.name.compareTo(b.name));
  final cache = '${pubCache()}/hosted/pub.dev';

  final b = StringBuffer()
    ..writeln('Ramble Voice')
    ..writeln('Copyright (C) the Ramble Voice contributors')
    ..writeln()
    ..writeln('Ramble Voice is licensed under the GNU General Public License,')
    ..writeln('version 3 or (at your option) any later version')
    ..writeln('(SPDX: GPL-3.0-or-later). See the LICENSE file.')
    ..writeln()
    ..writeln('This file lists third-party software that Ramble Voice uses or')
    ..writeln('distributes, with its license.')
    ..writeln()
    ..writeln('== Gemma model weights ==')
    ..writeln()
    ..writeln('Gemma model weights are not distributed with Ramble Voice. They are')
    ..writeln('downloaded at runtime from Hugging Face and are licensed by Google')
    ..writeln('under the Apache License 2.0, not under the GPL.')
    ..writeln()
    ..writeln('== Runtime and native components ==')
    ..writeln()
    ..writeln('- Flutter framework and engine: BSD-3-Clause (Copyright The Flutter')
    ..writeln('  Authors).')
    ..writeln('- ardera/flutter-ci engine builds used by the Linux runner: MIT')
    ..writeln('  (packaging of the BSD-3-Clause Flutter engine), pinned by SHA-256.')
    ..writeln('- LiteRT-LM (via flutter_edge_ai): Apache-2.0.')
    ..writeln('- Roboto Flex font: SIL Open Font License 1.1 (OFL-1.1).')
    ..writeln('- gtk4-layer-shell: MIT.')
    ..writeln('- wtype (Flatpak build only): MIT.')
    ..writeln('- xdotool (Flatpak build only): BSD-3-Clause.')
    ..writeln('- GTK 4, GLib, PipeWire, PulseAudio client library, libsecret:')
    ..writeln('  LGPL/MIT, dynamically linked from the system or the Flatpak')
    ..writeln('  runtime.')
    ..writeln()
    ..writeln('== Dart and Flutter packages ==')
    ..writeln()
    ..writeln('Hosted packages from pubspec.lock (includes build-time tools).')
    ..writeln('License names are detected from each package\'s LICENSE file;')
    ..writeln('read the file in the package for the authoritative text.')
    ..writeln();

  var unknown = 0;
  for (final p in pkgs) {
    final dir = Directory('$cache/${p.name}-${p.version}');
    var license = 'NOT FOUND IN PUB CACHE (run flutter pub get)';
    if (dir.existsSync()) {
      final f = dir
          .listSync()
          .whereType<File>()
          .where((f) => RegExp(r'^(licen[sc]e|copying)(\.[a-z]+)?$',
                  caseSensitive: false)
              .hasMatch(f.uri.pathSegments.last))
          .firstOrNull;
      license = f == null ? 'UNKNOWN (no LICENSE file)' : detectLicense(f.readAsStringSync());
    }
    if (license.startsWith('UNKNOWN') || license.startsWith('NOT FOUND')) {
      unknown++;
    }
    b.writeln('- ${p.name} ${p.version}: $license');
  }
  stdout.write(b);
  if (unknown > 0) {
    stderr.writeln('$unknown package(s) need manual license review.');
  }
}
