// SPDX-License-Identifier: GPL-3.0-or-later

/// Global push-to-talk shortcut through org.freedesktop.portal.GlobalShortcuts,
/// with documented fallbacks for desktops that lack the portal.
///
/// Fallbacks (the portal is missing on Sway, Hyprland, river and plain X11 WMs):
/// the user binds a key in the compositor/WM to run
/// `ramble_voice --start` on press and `--stop` on release (or `--toggle`).
/// The second process forwards the command to the running instance (GApplication
/// single instance in the GTK4 runner) which delivers it on the `ramble/cli`
/// channel; [cliCommands] exposes it. No X11 key grabbing is done in Dart, since
/// no plugin or FFI shim for XGrabKey is shipped.
library;

import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';

import '../../platform_services.dart';
import '../linux_environment.dart';
import 'portal.dart';

class PortalHotkeyService implements HotkeyService {
  PortalHotkeyService(
    this._portal,
    this._env, {
    MethodChannel cliChannel = const MethodChannel('ramble/cli'),
    this.shortcutId = 'dictate',
  }) {
    cliChannel.setMethodCallHandler((call) async {
      if (call.method == 'command' && call.arguments is String) {
        _cli.add(call.arguments as String);
      }
      return null;
    });
  }

  static const _iface = 'org.freedesktop.portal.GlobalShortcuts';

  final PortalClient _portal;
  final LinuxEnvironment _env;
  final String shortcutId;

  // Single-subscription controllers buffer events until the app listens.
  final _events = StreamController<HotkeyEvent>();
  final _cli = StreamController<String>();
  final _subs = <StreamSubscription<DBusSignal>>[];
  DBusObjectPath? _session;

  @override
  Stream<HotkeyEvent> get events => _events.stream;

  @override
  Stream<String> get cliCommands => _cli.stream;

  @override
  Future<HotkeyStatus> bind({
    String preferredTrigger = 'CTRL+ALT+space',
  }) async {
    final version = await _portal.interfaceVersion(_iface);
    if (version == null) return fallbackStatus(_env);
    try {
      return await _bindWithPortal(preferredTrigger, version);
    } on PortalException catch (e) {
      return HotkeyStatus(
        HotkeyBackend.none,
        message:
            'Global shortcut portal failed: ${e.message}. Alternatively:\n${bindingAdvice(_env)}',
      );
    } on DBusMethodResponseException catch (e) {
      return HotkeyStatus(
        HotkeyBackend.none,
        message:
            'Global shortcut portal failed: ${e.errorName}. Alternatively:\n${bindingAdvice(_env)}',
      );
    }
  }

  Future<HotkeyStatus> _bindWithPortal(
    String preferredTrigger,
    int version,
  ) async {
    await _closeSession();
    final sessionToken = portalToken('session');
    final created = await _portal.request(
      _iface,
      'CreateSession',
      options: {'session_handle_token': DBusString(sessionToken)},
      timeout: const Duration(seconds: 30),
    );
    if (!created.ok) {
      return const HotkeyStatus(
        HotkeyBackend.none,
        message: 'The desktop refused to create a global shortcut session.',
      );
    }
    final session = DBusObjectPath(
      created.results['session_handle']?.asString() ??
          (await _portal.sessionPath(sessionToken)).value,
    );
    _session = session;
    _listen(session);

    final bound = await _portal.request(
      _iface,
      'BindShortcuts',
      leading: [
        session,
        DBusArray(DBusSignature('(sa{sv})'), [
          DBusStruct([
            DBusString(shortcutId),
            DBusDict.stringVariant({
              'description': DBusString(
                'Start or stop dictation (hold to talk)',
              ),
              'preferred_trigger': DBusString(preferredTrigger),
            }),
          ]),
        ]),
        DBusString(''),
      ],
      timeout: const Duration(minutes: 5),
    );
    if (!bound.ok) {
      await _closeSession();
      return HotkeyStatus(
        HotkeyBackend.none,
        message: bound.code == PortalResponseCode.cancelled
            ? 'Shortcut setup was cancelled. Choose a key in Settings to enable the global shortcut.'
            : 'The desktop could not bind the shortcut.',
      );
    }
    final trigger =
        _triggerFrom(bound.results['shortcuts']) ??
        await _listTrigger(session) ??
        prettyTrigger(preferredTrigger);
    return HotkeyStatus(
      HotkeyBackend.portal,
      trigger: trigger,
      supportsRelease: true,
    );
  }

  void _listen(DBusObjectPath session) {
    for (final entry in {
      'Activated': HotkeyPhase.pressed,
      'Deactivated': HotkeyPhase.released,
    }.entries) {
      _subs.add(
        DBusSignalStream(
          _portal.bus,
          sender: portalBusName,
          interface: _iface,
          name: entry.key,
          path: portalPath,
        ).listen((s) {
          if (s.values.length < 2) return;
          if (s.values[0].asObjectPath() != session ||
              s.values[1].asString() != shortcutId)
            return;
          _events.add(HotkeyEvent(entry.value));
        }),
      );
    }
  }

  Future<String?> _listTrigger(DBusObjectPath session) async {
    try {
      final r = await _portal.request(
        _iface,
        'ListShortcuts',
        leading: [session],
        timeout: const Duration(seconds: 10),
      );
      return r.ok ? _triggerFrom(r.results['shortcuts']) : null;
    } catch (_) {
      return null;
    }
  }

  /// Extracts the human-readable trigger of our shortcut from an `a(sa{sv})`
  /// value (wrapped in a variant inside Response results).
  String? _triggerFrom(DBusValue? shortcuts) {
    if (shortcuts == null) return null;
    final list = shortcuts is DBusVariant ? shortcuts.value : shortcuts;
    if (list is! DBusArray) return null;
    for (final item in list.children) {
      if (item is! DBusStruct || item.children.length < 2) continue;
      if (item.children[0].asString() != shortcutId) continue;
      final props = item.children[1].asStringVariantDict();
      final d = props['trigger_description'];
      if (d is DBusString && d.value.isNotEmpty) return d.value;
    }
    return null;
  }

  @override
  Future<bool> configure() async {
    final session = _session;
    if (session == null) return false;
    final version = await _portal.interfaceVersion(_iface) ?? 0;
    if (version < 2) return false;
    try {
      await _portal.desktop.callMethod(_iface, 'ConfigureShortcuts', [
        session,
        DBusString(''),
        DBusDict.stringVariant({}),
      ]);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _closeSession() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final session = _session;
    _session = null;
    if (session == null) return;
    try {
      await DBusRemoteObject(
        _portal.bus,
        name: portalBusName,
        path: session,
      ).callMethod('org.freedesktop.portal.Session', 'Close', const []);
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    await _closeSession();
    unawaited(_events.close());
    unawaited(_cli.close());
  }

  /// "CTRL+ALT+space" -> "Ctrl+Alt+Space".
  static String prettyTrigger(String t) => t
      .split('+')
      .map(
        (p) => switch (p.toUpperCase()) {
          'CTRL' || 'CONTROL' => 'Ctrl',
          'ALT' => 'Alt',
          'SHIFT' => 'Shift',
          'LOGO' || 'SUPER' || 'META' => 'Super',
          _ => p.isEmpty ? p : p[0].toUpperCase() + p.substring(1),
        },
      )
      .join('+');

  /// What to tell the user when no portal is available: the exact lines to put
  /// in their compositor or window manager config.
  static HotkeyStatus fallbackStatus(LinuxEnvironment env) {
    final backend = env.isWayland
        ? HotkeyBackend.compositorBinding
        : HotkeyBackend.x11;
    return HotkeyStatus(
      backend,
      trigger: null,
      supportsRelease: true,
      message:
          'This desktop (${env.desktopLabel}) has no global shortcut portal, so bind a key yourself.\n${bindingAdvice(env)}',
    );
  }

  /// Exact config lines for the user's compositor or window manager.
  static String bindingAdvice(LinuxEnvironment env) {
    final cmd = env.cliCommand;
    final String help;
    switch (env.desktops.firstWhere(
      (d) => const [
        'sway',
        'hyprland',
        'river',
        'niri',
        'i3',
        'bspwm',
      ].contains(d),
      orElse: () => '',
    )) {
      case 'sway':
        help =
            'Add to ~/.config/sway/config:\n'
            '  bindsym Ctrl+Alt+space exec $cmd --start\n'
            '  bindsym --release Ctrl+Alt+space exec $cmd --stop\n'
            'For tap-to-toggle instead, use one line: bindsym Ctrl+Alt+space exec $cmd --toggle';
      case 'hyprland':
        help =
            'Add to ~/.config/hypr/hyprland.conf:\n'
            '  bind = CTRL ALT, space, exec, $cmd --start\n'
            '  bindr = CTRL ALT, space, exec, $cmd --stop\n'
            'For tap-to-toggle instead: bind = CTRL ALT, space, exec, $cmd --toggle';
      case 'i3':
        help =
            'Add to ~/.config/i3/config:\n'
            '  bindsym Ctrl+Mod1+space exec --no-startup-id $cmd --toggle';
      case 'niri':
        help =
            'Add to the binds block of ~/.config/niri/config.kdl:\n'
            '  Ctrl+Alt+Space { spawn ${env.isFlatpak ? '"flatpak" "run" "$rambleAppId"' : '"$rambleBinary"'} "--toggle"; }';
      default:
        help =
            'In your ${env.isWayland ? 'compositor' : 'window manager'}\'s keyboard settings, bind a key (e.g. Ctrl+Alt+Space) '
            'to the command "$cmd --toggle". For hold-to-talk, run "$cmd --start" on key press and "$cmd --stop" on key release.';
    }
    return help;
  }
}
