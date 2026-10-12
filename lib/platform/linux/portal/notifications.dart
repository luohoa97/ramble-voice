// SPDX-License-Identifier: GPL-3.0-or-later

/// Desktop notifications. Prefers org.freedesktop.portal.Notification (works
/// inside Flatpak and needs no extra permission) and falls back to
/// org.freedesktop.Notifications for hosts without a notification portal.
library;

import 'package:dbus/dbus.dart';

import '../../platform_services.dart';
import 'portal.dart';

class PortalNotifier implements SystemNotifier {
  PortalNotifier(this._portal, {this.appId = 'io.github.luohoa97.RambleVoice'});
  final PortalClient _portal;
  final String appId;

  bool? _portalWorks;

  /// Which backend delivered the last notification (diagnostics).
  String get backend => _portalWorks == true ? 'portal' : _portalWorks == false ? 'org.freedesktop.Notifications' : 'none yet';
  final Map<String, int> _legacyIds = {};

  DBusRemoteObject get _legacy => DBusRemoteObject(
        _portal.bus,
        name: 'org.freedesktop.Notifications',
        path: DBusObjectPath('/org/freedesktop/Notifications'),
      );

  @override
  Future<void> notify(String title, String body) => post('ramble-note', title, body);

  /// Shows (or replaces, when [id] was used before) a notification.
  /// [persistent] marks ongoing-status notifications that should not time out.
  Future<void> post(String id, String title, String body, {bool persistent = false, String icon = 'audio-input-microphone-symbolic'}) async {
    if (_portalWorks != false) {
      try {
        await _portal.desktop.callMethod('org.freedesktop.portal.Notification', 'AddNotification', [
          DBusString(id),
          DBusDict.stringVariant({
            'title': DBusString(title),
            'body': DBusString(body),
            'priority': DBusString(persistent ? 'low' : 'normal'),
            'icon': DBusStruct([DBusString('themed'), DBusVariant(DBusArray.string([icon]))]),
          }),
        ]);
        _portalWorks = true;
        return;
      } catch (_) {
        if (_portalWorks == true) rethrow;
        _portalWorks = false;
      }
    }
    await _postLegacy(id, title, body, persistent: persistent, icon: icon);
  }

  Future<void> _postLegacy(String id, String title, String body, {required bool persistent, required String icon}) async {
    final r = await _legacy.callMethod('org.freedesktop.Notifications', 'Notify', [
      DBusString('Ramble Voice'),
      DBusUint32(_legacyIds[id] ?? 0),
      DBusString(icon),
      DBusString(title),
      DBusString(body),
      DBusArray.string(const []),
      DBusDict.stringVariant({
        'desktop-entry': DBusString(appId),
        if (persistent) 'resident': DBusBoolean(true),
      }),
      DBusInt32(persistent ? 0 : 6000),
    ]);
    _legacyIds[id] = r.returnValues[0].asUint32();
  }

  Future<void> remove(String id) async {
    if (_portalWorks == true) {
      try {
        await _portal.desktop.callMethod('org.freedesktop.portal.Notification', 'RemoveNotification', [DBusString(id)]);
      } catch (_) {}
      return;
    }
    final legacy = _legacyIds.remove(id);
    if (legacy != null) {
      try {
        await _legacy.callMethod('org.freedesktop.Notifications', 'CloseNotification', [DBusUint32(legacy)]);
      } catch (_) {}
    }
  }
}
