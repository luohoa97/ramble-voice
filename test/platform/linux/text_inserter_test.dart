// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/platform/linux/linux_environment.dart';
import 'package:ramble_voice/platform/linux/text_inserter.dart';
import 'package:ramble_voice/platform/platform_services.dart';

class Call {
  Call(this.exe, this.args, this.stdin);
  final String exe;
  final List<String> args;
  final String stdin;
}

LinuxEnvironment env(
  String desktop,
  String session, {
  Set<String> bins = const {},
  bool wayland = true,
}) => LinuxEnvironment.fromEnv({
  'XDG_CURRENT_DESKTOP': desktop,
  'XDG_SESSION_TYPE': session,
  if (wayland) 'WAYLAND_DISPLAY': 'wayland-0',
}, binaries: bins);

void main() {
  late List<Call> calls;
  late List<String> clipboard;
  Map<String, int> exitCodes = {};

  setUp(() {
    calls = [];
    clipboard = [];
    exitCodes = {};
  });

  LinuxTextInserter make(LinuxEnvironment e) => LinuxTextInserter(
    env: e,
    settle: Duration.zero,
    runner:
        (
          exe,
          args, {
          required stdin,
          environment,
          timeout = const Duration(seconds: 1),
        }) async {
          calls.add(Call(exe, args, stdin));
          return exitCodes[exe] ?? 0;
        },
    flutterClipboard: (t) async => clipboard.add(t),
  );

  test('wtype receives the text on stdin only, never in arguments', () async {
    final ins = make(env('sway', 'wayland', bins: {'wtype'}));
    final r = await ins.insert(r'$(touch /tmp/x); --help "quoted"');
    expect(r.method, InsertMethod.typed);
    expect(r.backend, 'wtype');
    expect(calls.single.exe, 'wtype');
    expect(calls.single.args, ['-']);
    expect(calls.single.stdin, r'$(touch /tmp/x); --help "quoted"');
  });

  test('xdotool command line on X11', () async {
    final ins = make(env('XFCE', 'x11', bins: {'xdotool'}, wayland: false));
    await ins.insert('hello');
    expect(calls.single.args, [
      'type',
      '--clearmodifiers',
      '--delay',
      '2',
      '--file',
      '-',
    ]);
  });

  test('falls through to the next injector on failure', () async {
    final e = LinuxEnvironment.fromEnv(
      {
        'XDG_CURRENT_DESKTOP': 'sway',
        'XDG_SESSION_TYPE': 'wayland',
        'WAYLAND_DISPLAY': 'w',
      },
      binaries: {'wtype', 'ydotool'},
      ydotoolSocket: true,
    );
    exitCodes['wtype'] = 1;
    final r = await make(e).insert('hi');
    expect(r.backend, 'ydotool');
    expect(calls.map((c) => c.exe), ['wtype', 'ydotool']);
  });

  test('clipboard only when nothing can type', () async {
    final r = await make(env('GNOME', 'wayland')).insert('hello');
    expect(r.method, InsertMethod.clipboardOnly);
    expect(r.delivered, isFalse);
    expect(r.message, isNotEmpty);
    expect(clipboard, ['hello']);
  });

  test('clipboard fallback also uses wl-copy on Wayland', () async {
    final r = await make(env('GNOME', 'wayland', bins: {'wl-copy'}))
        .insert('hello');
    expect(r.method, InsertMethod.clipboardOnly);
    expect(calls.single.exe, 'wl-copy');
    expect(calls.single.stdin, 'hello');
  });

  test('empty text is a no-op', () async {
    final r = await make(env('sway', 'wayland', bins: {'wtype'})).insert('');
    expect(r.method, InsertMethod.none);
    expect(calls, isEmpty);
  });

  test('shouldPaste for long and non-BMP text', () {
    final ins = make(env('GNOME', 'wayland'));
    expect(ins.shouldPaste('short'), isFalse);
    expect(ins.shouldPaste('x' * 201), isTrue);
    expect(ins.shouldPaste('hi 😀'), isTrue);
  });

  test('describe', () async {
    expect(
      await make(env('sway', 'wayland', bins: {'wtype'})).describe(),
      startsWith('wtype'),
    );
    expect(
      await make(env('GNOME', 'wayland')).describe(),
      startsWith('Clipboard only'),
    );
  });
}
