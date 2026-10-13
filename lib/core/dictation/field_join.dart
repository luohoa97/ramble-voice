// SPDX-License-Identifier: GPL-3.0-or-later

/// Fits cleaned text into the field around the cursor. The model writes the
/// words; this makes the join exact, because model output is trimmed and a
/// model cannot be relied on for a leading line break or space:
/// - after a filled list item ("- milk|"), new list items start on a new line;
/// - right after an empty marker ("2. |"), a marker the model repeated is
///   dropped so it is not doubled;
/// - mid-text, a space separates words ("hello|" + "world").
abstract final class FieldJoin {
  /// A list marker at the start of a line: bullets, numbers, letters, task boxes.
  static final marker = RegExp(
    r'^([ \t]*)([-*] \[[ xX]\]|[-*+•◦▪‣]|\d+[.)]|[a-zA-Z][.)])[ \t]+',
  );

  static final _cjk = RegExp(r'[　-〿぀-ヿ㐀-䶿一-鿿＀-￯]');
  static final _wordStart = RegExp(
    r'''^[\p{L}\p{N}"'“‘(\[{¿¡#@$~/`*_-]''',
    unicode: true,
  );
  static final _wordEnd = RegExp(
    r'''[\p{L}\p{N}.,!?;:)\]}"'”’%]$''',
    unicode: true,
  );

  static String fit(String before, String text, [String after = '']) {
    // A leading line break from the model is its decision to start a new line.
    final lead = RegExp(r'^\n+').firstMatch(text)?.group(0) ?? '';
    var out = text.trim();
    if (out.isEmpty) return out;
    if (lead.isNotEmpty)
      return _tail(before.isEmpty ? out : '$lead$out', after);
    final line = before.substring(before.lastIndexOf('\n') + 1);
    final m = marker.firstMatch(line);
    if (m != null) {
      final rest = line.substring(m.end);
      final startsWithMarker = marker.hasMatch(out);
      if (rest.trim().isEmpty) {
        // "2. |": the field already has this item's marker.
        if (startsWithMarker) out = out.replaceFirst(marker, '');
        return _tail(out, after);
      }
      if (startsWithMarker) return _tail('\n$out', after);
    }
    if (before.isNotEmpty && !RegExp(r'\s$').hasMatch(before)) {
      final last = before.substring(before.length - 1);
      final cjk = _cjk.hasMatch(last) || _cjk.hasMatch(out.substring(0, 1));
      if (!cjk &&
          _wordEnd.hasMatch(last) &&
          _wordStart.hasMatch(out) &&
          !_isOpening(last)) {
        out = ' $out';
      }
    }
    return _tail(out, after);
  }

  static bool _isOpening(String c) => '([{"\'“‘/'.contains(c);

  /// A space before following text that starts a word ("|world").
  static String _tail(String out, String after) {
    if (after.isEmpty || RegExp(r'\s$').hasMatch(out)) return out;
    final first = after.substring(0, 1);
    final last = out.substring(out.length - 1);
    if (_cjk.hasMatch(first) || _cjk.hasMatch(last)) return out;
    if (RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(first) &&
        RegExp(r'[\p{L}\p{N}.,!?;:]', unicode: true).hasMatch(last)) {
      return '$out ';
    }
    return out;
  }
}
