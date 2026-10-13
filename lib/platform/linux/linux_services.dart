// SPDX-License-Identifier: GPL-3.0-or-later

/// Wires the Linux desktop integrations into [PlatformServices].
///
/// Everything here is pure Dart, D-Bus, dart:ffi, processes and the runner's
/// method channels (`ramble/window`, `ramble/overlay`, `ramble/cli`); Flutter's
/// GTK3 plugins do not exist in the GTK4 runner.
///
/// The Settings screen can reach the concrete classes through the services:
/// `services.secrets is SecretServiceStore` (`describe()`), `services.inserter
/// is LinuxTextInserter` (`describe()`), and [linuxEnvironment] for the
/// diagnostic snapshot.
library;

import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:path/path.dart' as p;

import '../platform_services.dart';
import 'desktop_entry.dart';
import 'linux_hotkey_service.dart';
import 'linux_audio_source.dart';
import 'linux_environment.dart';
import 'portal/global_shortcuts.dart';
import 'portal/notifications.dart';
import 'portal/portal.dart';
import 'portal/remote_desktop.dart';
import 'portal/settings.dart';
import 'secret_service_store.dart';
import 'status_indicator.dart';
import 'text_inserter.dart';
import 'tray.dart';

export 'host_setup.dart';
export 'linux_environment.dart';
export 'linux_hotkey_service.dart' show LinuxHotkeyService;
export 'secret_service_store.dart' show SecretServiceStore;
export 'text_inserter.dart' show LinuxTextInserter;

LinuxEnvironment? _environment;

/// The environment snapshot taken by [createLinuxServices] (null before).
LinuxEnvironment? get linuxEnvironment => _environment;

/// Default app-private directory: `$XDG_DATA_HOME/<app id>` (inside Flatpak
/// XDG_DATA_HOME already points into `~/.var/app/<app id>/data`).
Directory defaultSupportDirectory() {
  final env = Platform.environment;
  final data =
      env['XDG_DATA_HOME'] ?? p.join(env['HOME'] ?? '.', '.local', 'share');
  return Directory(p.join(data, rambleAppId));
}

Future<PlatformServices> createLinuxServices({
  Directory? supportDir,
  String hotkeyKey = 'capslock',
}) async {
  final support = supportDir ?? defaultSupportDirectory();
  final bus = DBusClient.session();
  final portal = PortalClient(bus);
  if (!(Platform.environment['FLATPAK_ID'] ?? '').isNotEmpty) {
    // GNOME only grants GlobalShortcuts to apps with a desktop entry; write
    // one for source builds, give GIO a moment to index it, then register
    // (registration must precede every other portal request).
    try {
      if (await DesktopEntry.ensure(rambleAppId)) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    } catch (_) {}
    await portal.registerHostApp(rambleAppId);
  }

  LinuxEnvironment env;
  try {
    env = await LinuxEnvironment.detect(portal: portal);
  } catch (_) {
    env = await LinuxEnvironment.detect();
  }
  _environment = env;

  final notifier = PortalNotifier(portal);
  final remoteDesktop = env.hasPortal('RemoteDesktop')
      ? RemoteDesktopPortal(
          portal,
          tokenFile: File(p.join(support.path, 'remote-desktop-token')),
        )
      : null;
  final settings = PortalSettings(portal);

  return PlatformServices(
    audio: LinuxAudioSource(),
    secrets: SecretServiceStore(
      bus,
      fallbackFile: File(p.join(support.path, 'gemini-api-key')),
    ),
    inserter: LinuxTextInserter(env: env, portal: remoteDesktop),
    notifier: notifier,
    hotkeys: LinuxHotkeyService(
      PortalHotkeyService(portal, env),
      hotkeyKey: hotkeyKey,
    ),
    indicator: LinuxStatusIndicator(
      tray: StatusNotifierTray(bus),
      notifications: notifier,
    ),
    accentColor: settings.accentColor,
  );
}
