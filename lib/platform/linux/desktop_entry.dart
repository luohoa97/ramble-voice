// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:path/path.dart' as p;

/// Ensures `<appId>.desktop` exists for native (non-Flatpak) runs.
///
/// xdg-desktop-portal resolves an unsandboxed app's id through its desktop
/// entry. Without one, GNOME refuses GlobalShortcuts with
/// `org.freedesktop.portal.Error.NotAllowed`. Packages and Flatpak install the
/// entry themselves; for a bare bundle (built from source) we write a user
/// entry pointing at the running executable. Entries we did not write are
/// never touched.
abstract final class DesktopEntry {
  static const _marker = 'X-Ramble-Generated=true';

  /// Returns true when the entry was created or updated (callers should give
  /// the portal a moment to notice the new file).
  static Future<bool> ensure(String appId, {Map<String, String>? environment}) async {
    final env = environment ?? Platform.environment;
    if ((env['FLATPAK_ID'] ?? '').isNotEmpty) return false;
    if (await _installedSystemWide(appId, env)) return false;

    final dataHome = env['XDG_DATA_HOME']?.isNotEmpty == true
        ? env['XDG_DATA_HOME']!
        : p.join(env['HOME'] ?? '', '.local', 'share');
    final file = File(p.join(dataHome, 'applications', '$appId.desktop'));
    final contents = render(appId, Platform.resolvedExecutable);

    if (await file.exists()) {
      final current = await file.readAsString();
      if (!current.contains(_marker) || current == contents) return false;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(contents, flush: true);
    return true;
  }

  static String render(String appId, String executable) {
    final exec = executable.contains(' ') ? '"$executable"' : executable;
    return '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=Ramble Voice\n'
        'Comment=Speak a messy ramble, get clean text\n'
        'Exec=$exec %U\n'
        'Icon=${_icon(appId, executable)}\n'
        'Terminal=false\n'
        'Categories=Utility;Accessibility;\n'
        'Keywords=dictation;voice;speech;transcribe;\n'
        'StartupWMClass=$appId\n'
        'X-GNOME-UsesNotifications=true\n'
        '$_marker\n';
  }

  /// The bundle ships data/icon.png next to the executable; fall back to
  /// the themed icon name used by packages.
  static String _icon(String appId, String executable) {
    final bundled = p.join(p.dirname(executable), 'data', 'icon.png');
    return File(bundled).existsSync() ? bundled : appId;
  }

  static Future<bool> _installedSystemWide(String appId, Map<String, String> env) async {
    final dirs = (env['XDG_DATA_DIRS']?.isNotEmpty == true ? env['XDG_DATA_DIRS']! : '/usr/local/share:/usr/share')
        .split(':')
        .where((d) => d.isNotEmpty);
    for (final d in dirs) {
      if (await File(p.join(d, 'applications', '$appId.desktop')).exists()) return true;
    }
    return false;
  }
}
