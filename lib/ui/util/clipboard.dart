// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

Future<void> copyToClipboard(
  BuildContext context,
  String text, {
  String message = 'Copied',
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
  );
}
