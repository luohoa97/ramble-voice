// SPDX-License-Identifier: GPL-3.0-or-later

/// org.freedesktop.portal.Settings: desktop accent colour and colour scheme.
library;

import 'dart:ui' show Color;

import 'package:dbus/dbus.dart';

import 'portal.dart';

enum PortalColorScheme { noPreference, dark, light }

class PortalSettings {
  PortalSettings(this._portal);
  final PortalClient _portal;

  static const _iface = 'org.freedesktop.portal.Settings';
  static const _appearance = 'org.freedesktop.appearance';

  /// Reads one setting. Uses ReadOne (v2) and falls back to the deprecated
  /// Read, which wraps the value in an extra variant.
  Future<DBusValue?> read(String namespace, String key) async {
    try {
      final r = await _portal.desktop.callMethod(_iface, 'ReadOne', [DBusString(namespace), DBusString(key)]);
      return r.returnValues[0].asVariant();
    } on DBusMethodResponseException catch (e) {
      if (e.errorName != 'org.freedesktop.DBus.Error.UnknownMethod') return null;
    } catch (_) {
      return null;
    }
    try {
      final r = await _portal.desktop.callMethod(_iface, 'Read', [DBusString(namespace), DBusString(key)]);
      var v = r.returnValues[0].asVariant();
      if (v is DBusVariant) v = v.value;
      return v;
    } catch (_) {
      return null;
    }
  }

  /// Accent colour as chosen in the desktop settings (GNOME 47+, KDE 6).
  /// Null when the desktop does not publish one or it is out of range.
  Future<Color?> accentColor() async => parseAccent(await read(_appearance, 'accent-color'));

  Future<PortalColorScheme> colorScheme() async {
    final v = await read(_appearance, 'color-scheme');
    final n = v is DBusUint32 ? v.value : 0;
    return n >= 0 && n < PortalColorScheme.values.length ? PortalColorScheme.values[n] : PortalColorScheme.noPreference;
  }

  /// `(ddd)` with components in 0..1; anything else (e.g. `(-1,-1,-1)`
  /// meaning "unset") yields null.
  static Color? parseAccent(DBusValue? v) {
    if (v is! DBusStruct || v.children.length != 3) return null;
    final c = v.children.map((e) => e is DBusDouble ? e.value : double.nan).toList();
    if (c.any((x) => x.isNaN || x < 0 || x > 1)) return null;
    return Color.from(alpha: 1, red: c[0], green: c[1], blue: c[2]);
  }
}
