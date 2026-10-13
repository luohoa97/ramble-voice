// SPDX-License-Identifier: GPL-3.0-or-later

/// Caps Lock as a hold-to-talk key, read straight from the kernel's evdev
/// devices.
///
/// GNOME's GlobalShortcuts portal cannot bind Caps Lock (or any key xkb can
/// remap it to), so on Linux we watch `/dev/input/eventN` ourselves. That
/// needs read access (membership of the `input` group).
///
/// Privacy: the kernel delivers every key of every keyboard on these nodes.
/// [InputEventParser] looks only at the Caps Lock key code and throws every
/// other record away as it is parsed; nothing is buffered beyond one partial
/// record, logged or exposed.
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import '../platform_services.dart';

const evKey = 1;
const keyCapsLock = 58;

/// Shown when no input device can be read.
const evdevPermissionMessage = 'Ramble needs permission to read the Caps Lock key. '
    'Run: sudo usermod -aG input \$USER, then log out and back in. '
    'Until then, use the desktop shortcut (Ctrl+Alt+Space).';

/// The command from [evdevPermissionMessage], for a copy button.
const evdevPermissionCommand = r'sudo usermod -aG input $USER';

/// One block of `/proc/bus/input/devices`.
class InputDeviceInfo {
  const InputDeviceInfo({required this.name, required this.eventPath, required this.hasCapsLock});
  final String name;

  /// e.g. `/dev/input/event3`.
  final String eventPath;
  final bool hasCapsLock;
}

/// Parses `/proc/bus/input/devices` and returns the devices that have an
/// event node and report EV_KEY with KEY_CAPSLOCK (keyboards).
///
/// Bitmaps are hex words, most significant first, each as wide as the
/// kernel's `unsigned long` ([wordBits]).
List<InputDeviceInfo> parseInputDevices(String text, {int? wordBits}) {
  final bits = wordBits ?? ffi.sizeOf<ffi.IntPtr>() * 8;
  final result = <InputDeviceInfo>[];
  for (final block in text.split(RegExp(r'\r?\n\s*\r?\n'))) {
    String? name;
    String? event;
    String? ev;
    String? key;
    for (final line in block.split('\n')) {
      if (line.startsWith('N: Name=')) {
        name = line.substring(8).trim().replaceAll('"', '');
      } else if (line.startsWith('H: Handlers=')) {
        event = RegExp(r'\bevent(\d+)\b').firstMatch(line)?.group(1);
      } else if (line.startsWith('B: EV=')) {
        ev = line.substring(6).trim();
      } else if (line.startsWith('B: KEY=')) {
        key = line.substring(7).trim();
      }
    }
    if (event == null || ev == null || key == null) continue;
    if (!_bitSet(ev, evKey, bits) || !_bitSet(key, keyCapsLock, bits)) continue;
    result.add(InputDeviceInfo(name: name ?? 'unknown', eventPath: '/dev/input/event$event', hasCapsLock: true));
  }
  return result;
}

bool _bitSet(String bitmap, int bit, int wordBits) {
  final words = bitmap.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final fromEnd = bit ~/ wordBits;
  if (fromEnd >= words.length) return false;
  final word = BigInt.tryParse(words[words.length - 1 - fromEnd], radix: 16);
  if (word == null) return false;
  return (word >> (bit % wordBits)) & BigInt.one == BigInt.one;
}

/// Incremental parser for `struct input_event` records.
///
/// 64-bit: 16-byte timeval + u16 type + u16 code + s32 value = 24 bytes;
/// 32-bit: 8-byte timeval, 16 bytes in all. Only Caps Lock transitions come
/// out: press (value 1) and release (value 0). Autorepeat (2) and every other
/// event or key are dropped.
class InputEventParser {
  InputEventParser({int? recordSize}) : recordSize = recordSize ?? (ffi.sizeOf<ffi.IntPtr>() == 8 ? 24 : 16);

  final int recordSize;
  final _partial = BytesBuilder(copy: false);

  List<HotkeyPhase> add(List<int> chunk) {
    Uint8List data;
    if (_partial.isEmpty) {
      data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    } else {
      _partial.add(chunk);
      data = _partial.takeBytes();
    }
    final out = <HotkeyPhase>[];
    final timeval = recordSize - 8;
    var offset = 0;
    for (; offset + recordSize <= data.length; offset += recordSize) {
      final view = ByteData.sublistView(data, offset, offset + recordSize);
      if (view.getUint16(timeval, Endian.host) != evKey) continue;
      if (view.getUint16(timeval + 2, Endian.host) != keyCapsLock) continue;
      switch (view.getInt32(timeval + 4, Endian.host)) {
        case 1:
          out.add(HotkeyPhase.pressed);
        case 0:
          out.add(HotkeyPhase.released);
      }
    }
    if (offset < data.length) _partial.add(Uint8List.sublistView(data, offset));
    return out;
  }
}

/// Result of [EvdevHotkey.start].
class EvdevStatus {
  const EvdevStatus({required this.devices, required this.denied});

  /// Keyboards that are being read.
  final int devices;

  /// Keyboards found but not readable (EACCES).
  final int denied;

  bool get readable => devices > 0;
  bool get permissionDenied => devices == 0 && denied > 0;
}

/// Watches every readable keyboard for Caps Lock.
class EvdevHotkey {
  EvdevHotkey({
    this.devicesFile = '/proc/bus/input/devices',
    this.rescan = const Duration(seconds: 5),
    this.openDevice = _openDevice,
  });

  final String devicesFile;
  final Duration rescan;

  /// Opens a device for reading; throws [FileSystemException] when it cannot.
  /// Injectable for tests.
  final Future<Stream<List<int>>> Function(String path) openDevice;

  final _events = StreamController<HotkeyEvent>.broadcast();
  final _active = <String, StreamSubscription<List<int>>>{};
  final _denied = <String>{};
  Timer? _timer;
  var _down = false;
  var _scanning = false;

  Stream<HotkeyEvent> get events => _events.stream;

  static Future<Stream<List<int>>> _openDevice(String path) async {
    final file = File(path);
    // Surfaces EACCES here instead of as a stream error later.
    final probe = await file.open();
    await probe.close();
    return file.openRead();
  }

  Future<EvdevStatus> start() async {
    await _scan();
    _timer?.cancel();
    _timer = Timer.periodic(rescan, (_) => _scan());
    return EvdevStatus(devices: _active.length, denied: _denied.length);
  }

  Future<void> _scan() async {
    if (_scanning) return;
    _scanning = true;
    try {
      final String text;
      try {
        text = await File(devicesFile).readAsString();
      } on FileSystemException {
        return;
      }
      for (final device in parseInputDevices(text)) {
        final path = device.eventPath;
        if (_active.containsKey(path) || _denied.contains(path)) continue;
        try {
          final stream = await openDevice(path);
          final parser = InputEventParser();
          void gone() => _active.remove(path);
          _active[path] = stream.listen(
            (chunk) {
              for (final phase in parser.add(chunk)) {
                // Several keyboards may report the same key; collapse.
                if (phase == HotkeyPhase.pressed ? _down : !_down) continue;
                _down = phase == HotkeyPhase.pressed;
                if (!_events.isClosed) _events.add(HotkeyEvent(phase));
              }
            },
            onError: (Object _) => gone(),
            onDone: gone,
            cancelOnError: true,
          );
        } on FileSystemException catch (e) {
          // EACCES stays denied until the app restarts (group changes need a
          // new login anyway); a vanished node is simply retried.
          if (e.osError?.errorCode == 13) _denied.add(path);
        }
      }
    } finally {
      _scanning = false;
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final subs = _active.values.toList();
    _active.clear();
    for (final s in subs) {
      await s.cancel();
    }
    _down = false;
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}

/// Edits GNOME's xkb options so Caps Lock stops toggling capitals while
/// Ramble owns the key (`caps:none`). Pure list logic plus a thin gsettings
/// wrapper; nothing here runs unless the desktop is GNOME.
///
/// KDE (not automated): put `Options=caps:none` under `[Layout]` in
/// `~/.config/kxkbrc` (`kwriteconfig6 --file kxkbrc --group Layout --key
/// Options caps:none`), then re-apply the layout.
class XkbCapsRemap {
  XkbCapsRemap({
    Map<String, String>? environment,
    Future<ProcessResult> Function(String exe, List<String> args)? run,
  })  : _env = environment ?? Platform.environment,
        _run = run ?? Process.run;

  static const schema = 'org.gnome.desktop.input-sources';
  static const key = 'xkb-options';
  static const option = 'caps:none';

  final Map<String, String> _env;
  final Future<ProcessResult> Function(String exe, List<String> args) _run;

  bool get supported => (_env['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase().split(':').contains('GNOME');

  /// `['a', 'b']` or `@as []` -> list.
  static List<String> parse(String gvariant) =>
      [for (final m in RegExp(r"'([^']*)'").allMatches(gvariant)) m.group(1)!];

  static String format(List<String> options) => options.isEmpty ? '@as []' : "[${options.map((o) => "'$o'").join(', ')}]";

  /// Drops every other `caps:*` entry and adds `caps:none`.
  static List<String> withCapsNone(List<String> options) =>
      [...options.where((o) => !o.startsWith('caps:')), option];

  static List<String> withoutCapsNone(List<String> options) => [...options.where((o) => o != option)];

  /// Returns false when unsupported or gsettings failed.
  Future<bool> setCapsDisabled(bool disabled) async {
    if (!supported) return false;
    try {
      final got = await _run('gsettings', ['get', schema, key]);
      if (got.exitCode != 0) return false;
      final current = parse('${got.stdout}');
      final next = disabled ? withCapsNone(current) : withoutCapsNone(current);
      if (next.length == current.length && next.every(current.contains)) return true;
      final set = await _run('gsettings', ['set', schema, key, format(next)]);
      return set.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}
