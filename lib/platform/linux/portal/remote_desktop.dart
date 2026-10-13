// SPDX-License-Identifier: GPL-3.0-or-later

/// Types text into the focused application through the
/// org.freedesktop.portal.RemoteDesktop portal (keyboard only). The user
/// consents once; a restore token (persist_mode 2) is stored so later sessions
/// start without a dialog.
///
/// Text is sent character by character as X11 keysyms. The compositor maps
/// each keysym to the right key (plus Shift or a temporary keymap entry for
/// characters missing from the layout), so no keyboard layout knowledge is
/// needed here. Content is never interpreted: every code point is typed as a
/// plain character.
library;

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'portal.dart';

abstract final class Keysyms {
  static const controlL = 0xffe3;
  static const returnKey = 0xff0d;
  static const tab = 0xff09;
  static const v = 0x76;

  /// X11 keysym for a Unicode code point, or null if it should be skipped
  /// (control characters other than newline and tab).
  static int? forCodePoint(int cp) {
    if (cp == 0x0a) return returnKey;
    if (cp == 0x09) return tab;
    if (cp < 0x20 || cp == 0x7f || (cp >= 0x80 && cp < 0xa0)) return null;
    if (cp <= 0x7e || (cp >= 0xa0 && cp <= 0xff)) return cp; // Latin-1 maps 1:1
    if (cp > 0x10ffff) return null;
    return 0x01000000 + cp;
  }

  /// Keysyms for [text]. CRLF is typed as one Enter.
  static List<int> forText(String text) {
    final out = <int>[];
    final runes = text.runes.toList();
    for (var i = 0; i < runes.length; i++) {
      if (runes[i] == 0x0d) {
        if (i + 1 < runes.length && runes[i + 1] == 0x0a) continue;
        out.add(returnKey);
        continue;
      }
      final k = forCodePoint(runes[i]);
      if (k != null) out.add(k);
    }
    return out;
  }
}

class RemoteDesktopUnavailable implements Exception {
  const RemoteDesktopUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

class RemoteDesktopPortal {
  RemoteDesktopPortal(this._portal, {required this.tokenFile, this.keyDelay = const Duration(milliseconds: 2)});

  static const _iface = 'org.freedesktop.portal.RemoteDesktop';

  final PortalClient _portal;

  /// Where the restore token is persisted (0600).
  final File tokenFile;
  final Duration keyDelay;

  DBusObjectPath? _session;
  Future<DBusObjectPath>? _starting;
  StreamSubscription<DBusSignal>? _closedSub;

  Future<int?> version() => _portal.interfaceVersion(_iface);

  /// Whether a session is already running (no dialog needed to type).
  bool get hasSession => _session != null;

  /// Makes sure a keyboard session exists, asking for consent when needed.
  Future<void> ensureSession() async {
    if (_session != null) return;
    await (_starting ??= _start().whenComplete(() => _starting = null));
  }

  Future<DBusObjectPath> _start() async {
    final v = await version();
    if (v == null) throw const RemoteDesktopUnavailable('The RemoteDesktop portal is not available.');

    final sessionToken = portalToken('session');
    final created = await _portal.request(_iface, 'CreateSession',
        options: {'session_handle_token': DBusString(sessionToken)}, timeout: const Duration(seconds: 30));
    if (!created.ok) throw const RemoteDesktopUnavailable('The desktop refused a RemoteDesktop session.');
    final session = DBusObjectPath(created.results['session_handle']?.asString() ?? (await _portal.sessionPath(sessionToken)).value);

    try {
      final restore = v >= 2 ? await _readToken() : null;
      final selected = await _portal.request(
        _iface,
        'SelectDevices',
        leading: [session],
        options: {
          'types': DBusUint32(1), // KEYBOARD
          if (v >= 2) 'persist_mode': DBusUint32(2),
          if (restore != null) 'restore_token': DBusString(restore),
        },
        timeout: const Duration(seconds: 30),
      );
      if (!selected.ok) throw const RemoteDesktopUnavailable('The desktop does not allow keyboard control.');

      final started = await _portal.request(
        _iface,
        'Start',
        leading: [session, DBusString('')],
        timeout: const Duration(minutes: 5),
      );
      if (!started.ok) {
        throw RemoteDesktopUnavailable(started.code == PortalResponseCode.cancelled
            ? 'Keyboard access was declined.'
            : 'The desktop could not start keyboard access.');
      }
      final devices = started.results['devices'];
      if (devices is DBusUint32 && devices.value & 1 == 0) {
        throw const RemoteDesktopUnavailable('The desktop did not grant keyboard access.');
      }
      final token = started.results['restore_token'];
      if (token is DBusString && token.value.isNotEmpty) await _writeToken(token.value);
    } catch (_) {
      await _close(session);
      rethrow;
    }

    _session = session;
    _closedSub = DBusSignalStream(
      _portal.bus,
      sender: portalBusName,
      interface: 'org.freedesktop.portal.Session',
      name: 'Closed',
      path: session,
    ).listen((_) => _forget(session));
    return session;
  }

  void _forget(DBusObjectPath session) {
    if (_session == session) _session = null;
    _closedSub?.cancel();
    _closedSub = null;
  }

  Future<String?> _readToken() async {
    try {
      final t = (await tokenFile.readAsString()).trim();
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeToken(String token) async {
    try {
      await tokenFile.parent.create(recursive: true);
      await tokenFile.writeAsString(token, flush: true);
      await Process.run('chmod', ['600', tokenFile.path]);
    } catch (_) {
      // Without a token the user is simply asked again next time.
    }
  }

  Future<void> _key(DBusObjectPath session, int keysym, bool pressed) =>
      _portal.desktop.callMethod(_iface, 'NotifyKeyboardKeysym', [
        session,
        DBusDict.stringVariant({}),
        DBusInt32(keysym),
        DBusUint32(pressed ? 1 : 0),
      ]);

  Future<void> _tap(DBusObjectPath session, int keysym) async {
    await _key(session, keysym, true);
    await _key(session, keysym, false);
  }

  /// Types [text]. Throws [RemoteDesktopUnavailable] when access was denied.
  Future<void> typeText(String text) => _withSession((s) async {
        for (final k in Keysyms.forText(text)) {
          await _tap(s, k);
          if (keyDelay > Duration.zero) await Future<void>.delayed(keyDelay);
        }
      });

  /// Sends Ctrl+V.
  Future<void> pasteShortcut() => _withSession((s) async {
        await _key(s, Keysyms.controlL, true);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await _tap(s, Keysyms.v);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await _key(s, Keysyms.controlL, false);
      });

  Future<void> _withSession(Future<void> Function(DBusObjectPath) body) async {
    await ensureSession();
    try {
      await body(_session!);
    } on DBusMethodResponseException {
      // The compositor may have dropped the session; start over once.
      final old = _session;
      if (old != null) _forget(old);
      await ensureSession();
      await body(_session!);
    }
  }

  Future<void> _close(DBusObjectPath session) async {
    try {
      await DBusRemoteObject(_portal.bus, name: portalBusName, path: session)
          .callMethod('org.freedesktop.portal.Session', 'Close', const []);
    } catch (_) {}
  }

  Future<void> dispose() async {
    final s = _session;
    if (s != null) {
      _forget(s);
      await _close(s);
    }
  }
}
