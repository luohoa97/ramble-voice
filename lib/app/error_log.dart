// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'providers.dart';

/// Local-only error log at `<support>/logs/dart.log` (never uploaded), so
/// failures that the UI only summarises can be diagnosed.
void installErrorLog(Directory support) {
  final log = File('${support.path}/logs/dart.log');
  try {
    log.parent.createSync(recursive: true);
    if (log.existsSync() && log.lengthSync() > 256 * 1024) log.renameSync('${log.path}.old');
  } catch (_) {}
  void write(String what, Object error, StackTrace? stack) {
    try {
      log.writeAsStringSync('${DateTime.now().toIso8601String()} $what: $error\n$stack\n\n', mode: FileMode.append);
    } catch (_) {}
  }

  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    write('FlutterError', details.exception, details.stack);
    previous?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    write('uncaught', error, stack);
    return false;
  };
  appErrorLog = write;
}
