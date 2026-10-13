// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

/// A local record of how dictation went: which engine and model, how long it
/// took, fallbacks and failures. Never the dictated text, never sent
/// anywhere: it stays in the app's private folder until the user shares it
/// (Settings, Privacy) to help fix a problem.
///
/// One JSON object per line, newest last, trimmed to [maxLines].
class UsageLog {
  UsageLog(this.file, {this.maxLines = 2000});

  final File file;
  final int maxLines;
  var _writes = 0;

  /// Appends [event] with a timestamp. Never throws.
  Future<void> record(String type, Map<String, Object?> fields) async {
    try {
      await file.parent.create(recursive: true);
      final line = jsonEncode({'at': DateTime.now().toIso8601String(), 'type': type, ...fields});
      await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
      if (++_writes % 50 == 0) await _trim();
    } catch (_) {
      // Diagnostics must never break dictation.
    }
  }

  Future<void> _trim() async {
    final lines = await file.readAsLines();
    if (lines.length <= maxLines) return;
    await file.writeAsString('${lines.sublist(lines.length - maxLines).join('\n')}\n', flush: true);
  }

  /// The newest [n] events, oldest first.
  Future<List<Map<String, Object?>>> recent([int n = 50]) async {
    if (!await file.exists()) return const [];
    final lines = await file.readAsLines();
    return [
      for (final l in lines.skip(lines.length > n ? lines.length - n : 0))
        if (l.trim().isNotEmpty) (jsonDecode(l) as Map).cast<String, Object?>(),
    ];
  }

  Future<String> readAll() async => await file.exists() ? file.readAsString() : '';

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}
