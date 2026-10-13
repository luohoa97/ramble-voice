// SPDX-License-Identifier: GPL-3.0-or-later

/// The Linux [HotkeyService]: Caps Lock read from evdev (hold to talk) plus
/// the desktop's GlobalShortcuts portal, whose shortcut keeps working as a
/// fallback. CLI commands come from the portal service.
library;

import 'dart:async';

import '../platform_services.dart';
import 'evdev_hotkey.dart';

class LinuxHotkeyService implements HotkeyService {
  LinuxHotkeyService(
    this._portal, {
    EvdevHotkey? evdev,
    XkbCapsRemap? xkb,
    String hotkeyKey = 'capslock',
  }) : _evdev = evdev ?? EvdevHotkey(),
       _xkb = xkb ?? XkbCapsRemap(),
       _key = hotkeyKey {
    _subs.add(_portal.events.listen(_events.add));
    _subs.add(_evdev.events.listen(_events.add));
  }

  final HotkeyService _portal;
  final EvdevHotkey _evdev;
  final XkbCapsRemap _xkb;
  final _events = StreamController<HotkeyEvent>.broadcast();
  final _subs = <StreamSubscription<HotkeyEvent>>[];
  String _key;
  String _trigger = 'CTRL+ALT+space';
  EvdevStatus? _evdevStatus;

  /// 'capslock' or 'portal'.
  String get hotkeyKey => _key;

  @override
  Stream<HotkeyEvent> get events => _events.stream;

  @override
  Stream<String> get cliCommands => _portal.cliCommands;

  @override
  Future<HotkeyStatus> bind({String preferredTrigger = 'CTRL+ALT+space'}) =>
      bindWithKey(_key, preferredTrigger: preferredTrigger);

  /// Applies the "Dictation key" setting and returns the resulting status.
  Future<HotkeyStatus> bindWithKey(
    String key, {
    String? preferredTrigger,
  }) async {
    _key = key;
    _trigger = preferredTrigger ?? _trigger;

    // evdev first: the portal can wait minutes on a permission dialog.
    EvdevStatus? evdev;
    if (key == 'capslock') {
      evdev = await _evdev.start();
      await _xkb.setCapsDisabled(evdev.readable);
      if (!evdev.readable) await _evdev.stop();
    } else {
      await _evdev.stop();
      await _xkb.setCapsDisabled(false);
    }
    _evdevStatus = evdev;

    // The portal shortcut stays bound in both modes.
    final portalStatus = await _portal.bind(preferredTrigger: _trigger);
    if (evdev == null) return portalStatus;
    if (evdev.readable)
      return const HotkeyStatus(
        HotkeyBackend.evdev,
        trigger: 'Caps Lock',
        supportsRelease: true,
      );
    return HotkeyStatus(
      portalStatus.backend,
      trigger: portalStatus.trigger,
      supportsRelease: portalStatus.supportsRelease,
      message: evdev.permissionDenied
          ? evdevPermissionMessage
          : 'No keyboard with a Caps Lock key was found. Use the desktop shortcut'
                '${portalStatus.trigger == null ? '' : ' (${portalStatus.trigger})'}.',
    );
  }

  /// Last evdev probe (null in portal mode); for UI status text.
  EvdevStatus? get evdevStatus => _evdevStatus;

  @override
  Future<bool> configure() => _portal.configure();

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _evdev.dispose();
    await _portal.dispose();
    await _events.close();
  }
}
