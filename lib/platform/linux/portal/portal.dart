// SPDX-License-Identifier: GPL-3.0-or-later

/// Helpers for the xdg-desktop-portal Request/Response pattern.
///
/// Most portal methods return immediately with a Request object path and
/// deliver their real result later as `org.freedesktop.portal.Request.Response`
/// on that path. The path is predictable
/// (`/org/freedesktop/portal/desktop/request/<sender>/<handle_token>`), so we
/// subscribe *before* calling to never miss a fast reply.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dbus/dbus.dart';

const portalBusName = 'org.freedesktop.portal.Desktop';
final portalPath = DBusObjectPath('/org/freedesktop/portal/desktop');

/// `response` values from the portal Request.Response signal.
enum PortalResponseCode { success, cancelled, other }

class PortalResponse {
  const PortalResponse(this.code, this.results);
  final PortalResponseCode code;
  final Map<String, DBusValue> results;

  bool get ok => code == PortalResponseCode.success;

  factory PortalResponse.fromSignal(DBusSignal signal) {
    final code = signal.values[0].asUint32();
    return PortalResponse(
      code == 0
          ? PortalResponseCode.success
          : code == 1
          ? PortalResponseCode.cancelled
          : PortalResponseCode.other,
      signal.values[1].asStringVariantDict(),
    );
  }
}

class PortalException implements Exception {
  const PortalException(this.message);
  final String message;
  @override
  String toString() => 'PortalException: $message';
}

final _rng = Random.secure();

/// A token valid in portal object paths (letters, digits, underscore).
String portalToken([String prefix = 'ramble']) =>
    '${prefix}_${_rng.nextInt(1 << 32).toRadixString(36)}${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

/// Thin wrapper over a session bus connection for portal calls.
class PortalClient {
  PortalClient(this.bus);
  final DBusClient bus;

  DBusRemoteObject get desktop =>
      DBusRemoteObject(bus, name: portalBusName, path: portalPath);

  /// Sender part of request paths: unique name without ':' and with '.' -> '_'.
  Future<String> _senderToken() async {
    await bus.ping();
    return bus.uniqueName.substring(1).replaceAll('.', '_');
  }

  /// Predicted Request path for [handleToken].
  Future<DBusObjectPath> requestPath(
    String handleToken,
  ) async => DBusObjectPath(
    '/org/freedesktop/portal/desktop/request/${await _senderToken()}/$handleToken',
  );

  /// Predicted Session path for [sessionToken].
  Future<DBusObjectPath> sessionPath(
    String sessionToken,
  ) async => DBusObjectPath(
    '/org/freedesktop/portal/desktop/session/${await _senderToken()}/$sessionToken',
  );

  bool _registered = false;

  /// Tells xdg-desktop-portal which application this is
  /// (`org.freedesktop.host.portal.Registry.Register`, portal 1.19+).
  ///
  /// Unsandboxed apps otherwise have no app id, and some backends (GNOME's
  /// GlobalShortcuts, notification grouping) refuse anonymous callers. The
  /// desktop entry `<appId>.desktop` must be installed for the id to resolve.
  /// Must run before the first request; ignored where unsupported or
  /// sandboxed (Flatpak already provides the id).
  Future<void> registerHostApp(String appId) async {
    if (_registered) return;
    _registered = true;
    try {
      await desktop.callMethod(
        'org.freedesktop.host.portal.Registry',
        'Register',
        [DBusString(appId), DBusDict.stringVariant({})],
      );
    } catch (e) {
      // Older portals lack the Registry; GNOME then refuses GlobalShortcuts.
      stderr.writeln('ramble: host portal registration failed: $e');
    }
  }

  /// Reads a portal interface version (`version` property), or null when the
  /// portal or interface is missing.
  Future<int?> interfaceVersion(String interface) async {
    try {
      final v = await desktop.getProperty(interface, 'version');
      return v.asUint32();
    } catch (_) {
      return null;
    }
  }

  /// Calls a portal method whose last argument is the `a{sv}` options dict
  /// and which answers through a Request. [leading] are the arguments before
  /// the options (for example the session handle). `handle_token` is added to
  /// [options]. Completes when the Response signal arrives.
  ///
  /// [timeout] guards against a dialog nobody answers; null waits forever.
  Future<PortalResponse> request(
    String interface,
    String method, {
    List<DBusValue> leading = const [],
    Map<String, DBusValue> options = const {},
    Duration? timeout,
  }) async {
    final token = portalToken('req');
    final path = await requestPath(token);
    final completer = Completer<PortalResponse>();
    StreamSubscription<DBusSignal> watch(DBusObjectPath p) =>
        DBusSignalStream(
          bus,
          sender: portalBusName,
          interface: 'org.freedesktop.portal.Request',
          name: 'Response',
          path: p,
        ).listen((signal) {
          if (!completer.isCompleted)
            completer.complete(PortalResponse.fromSignal(signal));
        });
    final sub = watch(path);
    try {
      // Make sure the match rule is installed before the call is sent.
      await Future<void>.delayed(Duration.zero);
      final reply = await desktop.callMethod(interface, method, [
        ...leading,
        DBusDict.stringVariant({...options, 'handle_token': DBusString(token)}),
      ], replySignature: DBusSignature('o'));
      final returned = reply.returnValues[0].asObjectPath();
      if (returned != path) {
        // Very old portals did not honour handle_token; follow the real path.
        final late = watch(returned);
        completer.future.whenComplete(late.cancel);
      }
      return await (timeout == null
          ? completer.future
          : completer.future.timeout(timeout));
    } on TimeoutException {
      throw PortalException(
        '$interface.$method timed out waiting for the user',
      );
    } finally {
      await sub.cancel();
    }
  }
}
