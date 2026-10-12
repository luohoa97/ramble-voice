// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/style/contact_names.dart';

/// Contact names through `ramble/system` `contactNames`. The native side
/// returns an empty list unless READ_CONTACTS is granted, so the keyboard and
/// the bubble can use this without asking; only the Activity prompts, with
/// [request].
class AndroidContactNames implements ContactNameSource {
  AndroidContactNames({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('ramble/system');

  final MethodChannel _channel;

  @override
  Future<List<String>> names() async {
    try {
      final list = await _channel.invokeListMethod<String>('contactNames');
      return list ?? const [];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Whether contacts access is granted.
  static Future<bool> isGranted() => Permission.contacts.isGranted;

  /// Asks for contacts access. Call from the Activity only.
  static Future<bool> request() async => (await Permission.contacts.request()).isGranted;
}
