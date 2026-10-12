// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter/services.dart';

/// Opens [url] in the default browser without a url_launcher plugin.
/// Linux: xdg-open. Android: `ramble/system` method `openUrl`.
/// Returns false when nothing could handle it.
Future<bool> openUrl(String url) async {
  try {
    if (Platform.isLinux) {
      await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
      return true;
    }
    if (Platform.isAndroid) {
      final ok = await const MethodChannel('ramble/system').invokeMethod<bool>('openUrl', url);
      return ok ?? true;
    }
  } catch (_) {}
  return false;
}
