// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'system_channel.dart';

/// The app name for an Android package ("com.google.android.gm" -> "Gmail").
/// Falls back to the package name.
final appLabelProvider = FutureProvider.family<String, String>(
  (ref, packageName) => SystemChannel.appLabel(packageName),
);
