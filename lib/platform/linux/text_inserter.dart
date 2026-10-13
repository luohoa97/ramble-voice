// SPDX-License-Identifier: GPL-3.0-or-later

/// Inserts dictated text into the focused application on Linux.
///
/// The path is chosen from the session (see [LinuxEnvironment.injectionChain]):
///
/// - GNOME / KDE Wayland: RemoteDesktop portal (typing, or clipboard + Ctrl+V
///   for long or non-BMP text), then `wtype`, then `ydotool`.
/// - wlroots compositors (Sway, Hyprland, river, niri, ...): `wtype -`.
/// - X11: `xdotool type --clearmodifiers --delay 2 --file -`.
/// - Anything with a ydotoold socket: `ydotool type --file -` as a last resort.
/// - Otherwise the text is only copied to the clipboard.
///
/// Text only ever travels over stdin or the portal; it is never placed in a
/// command line and never interpreted.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../platform_services.dart';
import 'linux_environment.dart';
import 'portal/remote_desktop.dart';

/// Runs a helper with [stdin] as input; returns its exit code, -1 if it could
/// not start and -2 on timeout.
typedef CommandRunner = Future<int> Function(
  String executable,
  List<String> args, {
  required String stdin,
  Map<String, String>? environment,
  Duration timeout,
});

Future<int> runCommand(
  String executable,
  List<String> args, {
  required String stdin,
  Map<String, String>? environment,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final Process process;
  try {
    process = await Process.start(executable, args, environment: environment);
  } on ProcessException {
    return -1;
  }
  // Helpers are quiet; discard output without waiting on the pipes (wl-copy
  // forks a child that keeps them open).
  process.stdout.drain<void>().ignore();
  process.stderr.drain<void>().ignore();
  try {
    process.stdin.add(utf8.encode(stdin));
    await process.stdin.close();
  } on SocketException {
    // The helper exited before reading everything; its exit code tells.
  } catch (_) {}
  try {
    return await process.exitCode.timeout(timeout);
  } on TimeoutException {
    process.kill();
    return -2;
  }
}

class LinuxTextInserter implements TextInserter {
  LinuxTextInserter({
    required this.env,
    this.portal,
    CommandRunner? runner,
    Future<void> Function(String text)? flutterClipboard,
    this.settle = const Duration(milliseconds: 120),
    this.pasteThreshold = 200,
    Map<String, String>? environment,
  }) : _run = runner ?? runCommand,
       _flutterClipboard =
           flutterClipboard ??
           ((t) => Clipboard.setData(ClipboardData(text: t))),
       _environment = environment ?? Platform.environment;

  final LinuxEnvironment env;
  final RemoteDesktopPortal? portal;
  final CommandRunner _run;
  final Future<void> Function(String) _flutterClipboard;
  final Map<String, String> _environment;

  /// Delay before typing so the hotkey's modifier keys are released.
  final Duration settle;

  /// Text longer than this goes through clipboard + Ctrl+V on the portal path.
  final int pasteThreshold;

  String? _lastFailure;

  /// Whether [text] should be pasted instead of typed key by key.
  bool shouldPaste(String text) =>
      text.length > pasteThreshold || text.runes.any((r) => r > 0xffff);

  @override
  Future<InsertResult> insert(String text) async {
    if (text.isEmpty) return const InsertResult(InsertMethod.none);
    await Future<void>.delayed(settle);
    _lastFailure = null;
    final failures = <String>[];

    for (final injector in env.injectionChain()) {
      final result = await _try(injector, text);
      if (result != null) return result;
      if (_lastFailure != null) failures.add(_lastFailure!);
    }

    final copied = await _copy(text);
    final why = failures.isEmpty ? _noInjectorHint() : failures.join(' ');
    return InsertResult(
      InsertMethod.clipboardOnly,
      backend: copied ? 'clipboard' : null,
      message:
          '${copied ? 'The text was copied. Press Ctrl+V to paste it. ' : 'Could not copy the text. '}$why',
    );
  }

  Future<InsertResult?> _try(Injector injector, String text) async {
    switch (injector) {
      case Injector.remoteDesktopPortal:
        final rd = portal;
        if (rd == null) return null;
        try {
          if (shouldPaste(text)) {
            if (!await _copy(text)) {
              _lastFailure =
                  'Could not place the text on the clipboard for pasting.';
              return null;
            }
            await Future<void>.delayed(const Duration(milliseconds: 40));
            await rd.pasteShortcut();
            return const InsertResult(
              InsertMethod.pasted,
              backend: 'RemoteDesktop portal',
            );
          }
          await rd.typeText(text);
          return const InsertResult(
            InsertMethod.typed,
            backend: 'RemoteDesktop portal',
          );
        } on RemoteDesktopUnavailable catch (e) {
          _lastFailure =
              '${e.message} Allow keyboard access for Ramble Voice when the desktop asks.';
        } catch (_) {
          _lastFailure = 'RemoteDesktop portal failed.';
        }
        return null;
      case Injector.wtype:
        return await _runHelper('wtype', ['-'], text, 'wtype');
      case Injector.xdotool:
        return await _runHelper(
          'xdotool',
          ['type', '--clearmodifiers', '--delay', '2', '--file', '-'],
          text,
          'xdotool',
        );
      case Injector.ydotool:
        final socket = LinuxEnvironment.ydotoolSocketPath(_environment);
        return await _runHelper(
          'ydotool',
          ['type', '--file', '-'],
          text,
          'ydotool',
          environment: socket == null ? null : {'YDOTOOL_SOCKET': socket},
        );
    }
  }

  Future<InsertResult?> _runHelper(
    String exe,
    List<String> args,
    String text,
    String label, {
    Map<String, String>? environment,
  }) async {
    final code = await _run(
      exe,
      args,
      stdin: text,
      environment: environment,
      timeout: Duration(seconds: 10 + text.length ~/ 40),
    );
    if (code == 0) return InsertResult(InsertMethod.typed, backend: label);
    _lastFailure = code == -1
        ? '$label could not be started.'
        : '$label failed (exit $code).';
    return null;
  }

  String _noInjectorHint() {
    if (env.isFlatpak)
      return 'No way to type into other apps is available in this sandbox.';
    if (env.isWayland) {
      return env.compositor == Compositor.gnome ||
              env.compositor == Compositor.kde
          ? 'Enable the RemoteDesktop portal (xdg-desktop-portal-${env.compositor == Compositor.gnome ? 'gnome' : 'kde'}) or install wtype/ydotool.'
          : 'Install wtype to type into other apps.';
    }
    return 'Install xdotool to type into other apps.';
  }

  @override
  Future<void> copy(String text) async {
    await _copy(text);
  }

  /// Puts [text] on the clipboard: Flutter's clipboard when the window can
  /// own it, plus `wl-copy` on Wayland so it also works while unfocused.
  Future<bool> _copy(String text) async {
    var ok = false;
    try {
      await _flutterClipboard(text);
      ok = true;
    } catch (_) {}
    if (env.isWayland && env.has('wl-copy')) {
      final code = await _run(
        'wl-copy',
        const [],
        stdin: text,
        timeout: const Duration(seconds: 3),
      );
      ok = ok || code == 0;
    }
    return ok;
  }

  @override
  Future<String> describe() async {
    final chain = env.injectionChain();
    if (chain.isEmpty) return 'Clipboard only (${_noInjectorHint()})';
    String label(Injector i) => switch (i) {
      Injector.remoteDesktopPortal => 'RemoteDesktop portal',
      Injector.wtype => 'wtype',
      Injector.xdotool => 'xdotool',
      Injector.ydotool => 'ydotool',
    };
    final session = '${env.desktopLabel}, ${env.isWayland ? 'Wayland' : 'X11'}';
    final first = label(chain.first);
    final rest = chain.length > 1
        ? ', then ${chain.skip(1).map(label).join(', then ')}'
        : '';
    return '$first ($session)$rest';
  }
}
