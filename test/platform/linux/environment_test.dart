// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/platform/linux/host_setup.dart';
import 'package:ramble_voice/platform/linux/linux_environment.dart';
import 'package:ramble_voice/platform/linux/portal/global_shortcuts.dart';
import 'package:ramble_voice/platform/platform_services.dart';

LinuxEnvironment env(
  String desktop,
  String session, {
  Set<String> bins = const {},
  bool socket = false,
  bool flatpak = false,
  bool rd = false,
  bool wayland = true,
}) => LinuxEnvironment.fromEnv(
  {
    'XDG_CURRENT_DESKTOP': desktop,
    'XDG_SESSION_TYPE': session,
    if (wayland) 'WAYLAND_DISPLAY': 'wayland-0',
  },
  binaries: bins,
  ydotoolSocket: socket,
  isFlatpak: flatpak,
  portalVersions: {'RemoteDesktop': rd ? 2 : null},
);

void main() {
  group('compositor detection', () {
    test('GNOME / Ubuntu', () {
      expect(env('GNOME', 'wayland').compositor, Compositor.gnome);
      expect(env('ubuntu:GNOME', 'wayland').compositor, Compositor.gnome);
    });
    test('KDE', () => expect(env('KDE', 'wayland').compositor, Compositor.kde));
    test('wlroots family', () {
      for (final d in ['sway', 'Hyprland', 'river', 'niri']) {
        expect(env(d, 'wayland').compositor, Compositor.wlroots, reason: d);
      }
    });
    test(
      'X11',
      () =>
          expect(env('XFCE', 'x11', wayland: false).compositor, Compositor.x11),
    );
  });

  group('injection chain', () {
    test('GNOME Wayland prefers the portal, then wtype, then ydotool', () {
      final e = env(
        'GNOME',
        'wayland',
        rd: true,
        bins: {'wtype', 'ydotool'},
        socket: true,
      );
      expect(e.injectionChain(), [
        Injector.remoteDesktopPortal,
        Injector.wtype,
        Injector.ydotool,
      ]);
    });
    test('Sway uses wtype first', () {
      final e = env('sway', 'wayland', bins: {'wtype'});
      expect(e.injectionChain(), [Injector.wtype]);
    });
    test('X11 uses xdotool', () {
      final e = env('XFCE', 'x11', wayland: false, bins: {'xdotool'});
      expect(e.injectionChain(), [Injector.xdotool]);
    });
    test('ydotool needs its socket', () {
      expect(
        env('sway', 'wayland', bins: {'ydotool'}).injectionChain(),
        isEmpty,
      );
      expect(
        env(
          'sway',
          'wayland',
          bins: {'ydotool'},
          socket: true,
        ).injectionChain(),
        [Injector.ydotool],
      );
    });
    test('nothing available means empty chain (clipboard only)', () {
      expect(env('GNOME', 'wayland').injectionChain(), isEmpty);
    });
    test('describe mentions the chain', () {
      expect(
        env('GNOME', 'wayland', rd: true).describe(),
        contains('remoteDesktopPortal'),
      );
    });
  });

  group('HostSetup', () {
    test('only for Flatpak without any typing path', () {
      expect(HostSetup.appliesTo(env('sway', 'wayland')), isFalse);
      expect(
        HostSetup.appliesTo(env('sway', 'wayland', flatpak: true)),
        isTrue,
      );
      expect(
        HostSetup.appliesTo(
          env('sway', 'wayland', flatpak: true, bins: {'wtype'}),
        ),
        isFalse,
      );
      expect(
        HostSetup.appliesTo(env('GNOME', 'wayland', flatpak: true, rd: true)),
        isFalse,
      );
      expect(HostSetup.command, contains('host-setup.sh'));
    });
  });

  group('hotkey fallback advice', () {
    test('Sway gets bindsym press and release lines', () {
      final s = PortalHotkeyService.fallbackStatus(env('sway', 'wayland'));
      expect(s.backend, HotkeyBackend.compositorBinding);
      expect(
        s.message,
        contains('bindsym Ctrl+Alt+space exec ramble_voice --start'),
      );
      expect(
        s.message,
        contains('bindsym --release Ctrl+Alt+space exec ramble_voice --stop'),
      );
    });
    test('Hyprland gets bind and bindr', () {
      final s = PortalHotkeyService.fallbackStatus(env('Hyprland', 'wayland'));
      expect(
        s.message,
        contains('bindr = CTRL ALT, space, exec, ramble_voice --stop'),
      );
    });
    test('Flatpak uses flatpak run', () {
      final s = PortalHotkeyService.fallbackStatus(
        env('sway', 'wayland', flatpak: true),
      );
      expect(
        s.message,
        contains('flatpak run io.github.luohoa97.RambleVoice --start'),
      );
    });
    test('X11 reports the x11 backend', () {
      final s = PortalHotkeyService.fallbackStatus(
        env('i3', 'x11', wayland: false),
      );
      expect(s.backend, HotkeyBackend.x11);
      expect(s.message, contains('--toggle'));
    });
    test('prettyTrigger', () {
      expect(
        PortalHotkeyService.prettyTrigger('CTRL+ALT+space'),
        'Ctrl+Alt+Space',
      );
    });
  });
}
