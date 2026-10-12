// SPDX-License-Identifier: GPL-3.0-or-later

/// Diagnostic snapshot of the Linux desktop session. Pure data plus a
/// detector, so selection logic (text injection chain, hotkey advice) can be
/// unit-tested without a session.
library;

import 'dart:io';

import 'portal/portal.dart';

const rambleAppId = 'io.github.luohoa97.RambleVoice';
const rambleBinary = 'ramble_voice';

enum SessionType { wayland, x11, other }

/// Coarse compositor family; decides which text injection path is preferred.
enum Compositor {
  /// Mutter (GNOME Shell): RemoteDesktop portal, no wlroots protocols.
  gnome,

  /// KWin (Plasma): RemoteDesktop portal.
  kde,

  /// wlroots based (Sway, Hyprland, river, niri, ...): virtual-keyboard works.
  wlroots,

  /// An X11 window manager.
  x11,
  other,
}

/// Ways to get text into another application.
enum Injector { remoteDesktopPortal, wtype, xdotool, ydotool }

class LinuxEnvironment {
  const LinuxEnvironment({
    this.desktops = const [],
    this.sessionType = SessionType.other,
    this.waylandDisplay = false,
    this.isFlatpak = false,
    this.binaries = const {},
    this.ydotoolSocket = false,
    this.portalVersions = const {},
  });

  /// `XDG_CURRENT_DESKTOP` split on ':' and lower-cased.
  final List<String> desktops;
  final SessionType sessionType;

  /// Whether `WAYLAND_DISPLAY` is set (true for Wayland sessions and
  /// XWayland-only environments such as a Flatpak without X11).
  final bool waylandDisplay;
  final bool isFlatpak;

  /// Helper binaries found on PATH (or /app/bin in Flatpak): wtype, xdotool,
  /// ydotool, wl-copy, wl-paste.
  final Set<String> binaries;
  final bool ydotoolSocket;

  /// Interface name suffix (`GlobalShortcuts`, `RemoteDesktop`, ...) to portal
  /// interface version; null when the interface is not offered.
  final Map<String, int?> portalVersions;

  bool get isWayland => sessionType == SessionType.wayland || (sessionType == SessionType.other && waylandDisplay);

  Compositor get compositor {
    bool has(String s) => desktops.any((d) => d.contains(s));
    if (has('gnome') || has('ubuntu') || has('unity')) return Compositor.gnome;
    if (has('kde') || has('plasma')) return Compositor.kde;
    const wlroots = ['sway', 'hyprland', 'river', 'niri', 'wayfire', 'labwc', 'wlroots', 'miracle', 'mango', 'dwl', 'scroll'];
    if (wlroots.any(has)) return Compositor.wlroots;
    if (!isWayland && sessionType == SessionType.x11) return Compositor.x11;
    return Compositor.other;
  }

  bool hasPortal(String name) => portalVersions[name] != null;
  bool has(String binary) => binaries.contains(binary);

  /// The command a compositor key binding must run, for shortcut advice.
  String get cliCommand => isFlatpak ? 'flatpak run $rambleAppId' : rambleBinary;

  String get desktopLabel => desktops.isEmpty ? 'unknown desktop' : desktops.join(':');

  /// Priority-ordered text injection candidates for this session. The first
  /// entry that works is used; later ones are tried when an earlier one fails.
  List<Injector> injectionChain() {
    final out = <Injector>[];
    final portal = hasPortal('RemoteDesktop');
    switch (compositor) {
      case Compositor.gnome:
      case Compositor.kde:
        if (portal) out.add(Injector.remoteDesktopPortal);
        if (isWayland && has('wtype')) out.add(Injector.wtype);
        if (!isWayland && has('xdotool')) out.add(Injector.xdotool);
      case Compositor.wlroots:
        if (has('wtype')) out.add(Injector.wtype);
        if (portal) out.add(Injector.remoteDesktopPortal);
      case Compositor.x11:
        if (has('xdotool')) out.add(Injector.xdotool);
        if (portal) out.add(Injector.remoteDesktopPortal);
      case Compositor.other:
        if (isWayland) {
          if (portal) out.add(Injector.remoteDesktopPortal);
          if (has('wtype')) out.add(Injector.wtype);
        } else {
          if (has('xdotool')) out.add(Injector.xdotool);
          if (portal) out.add(Injector.remoteDesktopPortal);
        }
    }
    if (has('ydotool') && ydotoolSocket) out.add(Injector.ydotool);
    return out;
  }

  String describe() {
    final b = StringBuffer()
      ..write('$desktopLabel, ${isWayland ? 'Wayland' : sessionType == SessionType.x11 ? 'X11' : 'unknown session'}')
      ..write(isFlatpak ? ', Flatpak' : '')
      ..write('; injectors: ')
      ..write(injectionChain().isEmpty ? 'none (clipboard only)' : injectionChain().map((i) => i.name).join(' > '))
      ..write('; portals: ')
      ..write(portalVersions.isEmpty ? 'none' : portalVersions.entries.map((e) => '${e.key}=${e.value ?? '-'}').join(' '));
    return b.toString();
  }

  /// Builds an environment from explicit inputs (used by [detect] and tests).
  factory LinuxEnvironment.fromEnv(
    Map<String, String> env, {
    Set<String> binaries = const {},
    bool ydotoolSocket = false,
    bool isFlatpak = false,
    Map<String, int?> portalVersions = const {},
  }) {
    final type = switch ((env['XDG_SESSION_TYPE'] ?? '').toLowerCase()) {
      'wayland' => SessionType.wayland,
      'x11' => SessionType.x11,
      _ => SessionType.other,
    };
    return LinuxEnvironment(
      desktops: (env['XDG_CURRENT_DESKTOP'] ?? '').toLowerCase().split(':').where((e) => e.isNotEmpty).toList(),
      sessionType: type,
      waylandDisplay: (env['WAYLAND_DISPLAY'] ?? '').isNotEmpty,
      isFlatpak: isFlatpak || (env['FLATPAK_ID'] ?? '').isNotEmpty,
      binaries: binaries,
      ydotoolSocket: ydotoolSocket,
      portalVersions: portalVersions,
    );
  }

  static const _tools = ['wtype', 'xdotool', 'ydotool', 'wl-copy', 'wl-paste'];
  static const _portalInterfaces = ['GlobalShortcuts', 'RemoteDesktop', 'Settings', 'Notification', 'Clipboard'];

  /// Inspects the running session. [portal] enables portal version probing.
  static Future<LinuxEnvironment> detect({PortalClient? portal}) async {
    final env = Platform.environment;
    final flatpak = File('/.flatpak-info').existsSync() || (env['FLATPAK_ID'] ?? '').isNotEmpty;
    final dirs = [
      ...(env['PATH'] ?? '').split(':').where((e) => e.isNotEmpty),
      if (flatpak) '/app/bin',
    ];
    final found = <String>{
      for (final t in _tools)
        if (dirs.any((d) => File('$d/$t').existsSync())) t,
    };
    final versions = <String, int?>{};
    if (portal != null) {
      final found = await Future.wait([
        for (final name in _portalInterfaces) portal.interfaceVersion('org.freedesktop.portal.$name'),
      ]);
      for (var i = 0; i < _portalInterfaces.length; i++) {
        versions[_portalInterfaces[i]] = found[i];
      }
    }
    return LinuxEnvironment.fromEnv(
      env,
      binaries: found,
      ydotoolSocket: ydotoolSocketPath(env) != null,
      isFlatpak: flatpak,
      portalVersions: versions,
    );
  }

  /// Path to a live ydotoold socket, or null.
  static String? ydotoolSocketPath(Map<String, String> env) {
    final candidates = [
      env['YDOTOOL_SOCKET'],
      if (env['XDG_RUNTIME_DIR'] != null) '${env['XDG_RUNTIME_DIR']}/.ydotool_socket',
      '/run/user/$_uid/.ydotool_socket',
      '/tmp/.ydotool_socket',
    ];
    for (final c in candidates) {
      if (c != null && c.isNotEmpty && FileSystemEntity.typeSync(c) == FileSystemEntityType.unixDomainSock) return c;
    }
    return null;
  }

  static int get _uid {
    try {
      return int.parse(Process.runSync('id', ['-u']).stdout.toString().trim());
    } catch (_) {
      return 1000;
    }
  }
}
