// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/platform_services.dart';

/// Latest result of binding the global shortcut (Linux).
class HotkeyStatusNotifier extends Notifier<HotkeyStatus?> {
  @override
  HotkeyStatus? build() => null;
  void set(HotkeyStatus? s) => state = s;
}

final hotkeyStatusProvider = NotifierProvider<HotkeyStatusNotifier, HotkeyStatus?>(HotkeyStatusNotifier.new);
