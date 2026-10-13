// SPDX-License-Identifier: GPL-3.0-or-later

/// System tray icon through the StatusNotifierItem D-Bus protocol, with a
/// minimal com.canonical.dbusmenu menu (start/stop dictation, show window,
/// quit). Works on KDE, Sway/waybar, Hyprland and GNOME with the AppIndicator
/// extension. On stock GNOME (no StatusNotifierWatcher) it does nothing and
/// reports [StatusNotifierTray.supported] as false; it keeps watching and
/// registers if a watcher appears later.
library;

import 'dart:async';
import 'dart:io' as io;

import 'package:dbus/dbus.dart';

import '../platform_services.dart';

/// Theme icon names per state.
String trayIconFor(IndicatorState s) => switch (s) {
  IndicatorState.idle => 'audio-input-microphone-symbolic',
  IndicatorState.listening => 'media-record-symbolic',
  IndicatorState.processing => 'emblem-synchronizing-symbolic',
  IndicatorState.error => 'dialog-warning-symbolic',
};

String trayTitleFor(IndicatorState s) => switch (s) {
  IndicatorState.idle => 'Ramble Voice',
  IndicatorState.listening => 'Ramble Voice: listening',
  IndicatorState.processing => 'Ramble Voice: cleaning up',
  IndicatorState.error => 'Ramble Voice: problem',
};

/// Menu entries; ids are stable because dbusmenu clients cache them.
enum TrayMenuItem {
  toggle(1),
  show(2),
  separator(3),
  quit(4);

  const TrayMenuItem(this.id);
  final int id;
}

String trayToggleLabel(IndicatorState s) =>
    s == IndicatorState.listening ? 'Stop dictation' : 'Start dictation';

/// Builds the dbusmenu `(ia{sv}av)` layout for the whole menu.
DBusStruct buildMenuLayout(IndicatorState state) {
  DBusValue item(TrayMenuItem i) {
    final props = switch (i) {
      TrayMenuItem.toggle => {'label': DBusString(trayToggleLabel(state))},
      TrayMenuItem.show => {'label': DBusString('Show window')},
      TrayMenuItem.separator => {'type': DBusString('separator')},
      TrayMenuItem.quit => {'label': DBusString('Quit')},
    };
    return DBusStruct([
      DBusInt32(i.id),
      DBusDict.stringVariant(props),
      DBusArray.variant(const []),
    ]);
  }

  return DBusStruct([
    DBusInt32(0),
    DBusDict.stringVariant({'children-display': DBusString('submenu')}),
    DBusArray.variant(TrayMenuItem.values.map(item)),
  ]);
}

class StatusNotifierTray {
  StatusNotifierTray(this._bus, {int? pid}) : _pid = pid ?? io.pid;

  static const _watcherName = 'org.kde.StatusNotifierWatcher';
  static const itemPath = '/StatusNotifierItem';
  static const menuPath = '/MenuBar';

  final DBusClient _bus;
  final int _pid;
  late final _TrayItemObject _item;
  late final _TrayMenuObject _menu;
  StreamSubscription<DBusNameOwnerChangedEvent>? _watchSub;
  String? _serviceName;
  bool _registered = false;
  IndicatorState _state = IndicatorState.idle;

  /// True once the tray host accepted our icon.
  bool get supported => _registered;

  Future<bool> start({
    required void Function() onToggle,
    required void Function() onShowWindow,
    required void Function() onQuit,
  }) async {
    _item = _TrayItemObject(this, onShowWindow);
    _menu = _TrayMenuObject(this, {
      TrayMenuItem.toggle: onToggle,
      TrayMenuItem.show: onShowWindow,
      TrayMenuItem.quit: onQuit,
    });
    try {
      await _bus.registerObject(_item);
      await _bus.registerObject(_menu);
      final name = 'org.kde.StatusNotifierItem-$_pid-1';
      try {
        final reply = await _bus.requestName(
          name,
          flags: {DBusRequestNameFlag.doNotQueue},
        );
        if (reply == DBusRequestNameReply.primaryOwner ||
            reply == DBusRequestNameReply.alreadyOwner)
          _serviceName = name;
      } catch (_) {
        // Sandboxed without own-name permission: register by object path.
      }
      _watchSub = _bus.nameOwnerChanged
          .where((e) => e.name == _watcherName && e.newOwner != null)
          .listen((_) => _register());
      return await _register();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _register() async {
    try {
      if (await _bus.getNameOwner(_watcherName) == null) return false;
      await DBusRemoteObject(
        _bus,
        name: _watcherName,
        path: DBusObjectPath('/StatusNotifierWatcher'),
      ).callMethod(_watcherName, 'RegisterStatusNotifierItem', [
        DBusString(_serviceName ?? itemPath),
      ]);
      _registered = true;
      return true;
    } catch (_) {
      _registered = false;
      return false;
    }
  }

  IndicatorState get state => _state;

  Future<void> setState(IndicatorState s) async {
    if (s == _state) return;
    _state = s;
    if (!_registered) return;
    await _item.emitSignal('org.kde.StatusNotifierItem', 'NewIcon');
    await _item.emitSignal('org.kde.StatusNotifierItem', 'NewTitle');
    await _item.emitSignal('org.kde.StatusNotifierItem', 'NewToolTip');
    await _item.emitSignal('org.kde.StatusNotifierItem', 'NewStatus', [
      DBusString(_statusFor(s)),
    ]);
    await _menu.layoutChanged();
  }

  static String _statusFor(IndicatorState s) => s == IndicatorState.idle
      ? 'Passive'
      : s == IndicatorState.error
      ? 'NeedsAttention'
      : 'Active';

  Future<void> dispose() async {
    await _watchSub?.cancel();
    try {
      await _bus.unregisterObject(_item);
      await _bus.unregisterObject(_menu);
      if (_serviceName != null) await _bus.releaseName(_serviceName!);
    } catch (_) {}
    _registered = false;
  }
}

class _TrayItemObject extends DBusObject {
  _TrayItemObject(this._tray, this._onActivate)
    : super(DBusObjectPath(StatusNotifierTray.itemPath));
  final StatusNotifierTray _tray;
  final void Function() _onActivate;

  static const _iface = 'org.kde.StatusNotifierItem';

  Map<String, DBusValue> get _props => {
    'Category': DBusString('ApplicationStatus'),
    'Id': DBusString('io.github.luohoa97.RambleVoice'),
    'Title': DBusString(trayTitleFor(_tray.state)),
    'Status': DBusString(StatusNotifierTray._statusFor(_tray.state)),
    'WindowId': DBusUint32(0),
    'IconName': DBusString(trayIconFor(_tray.state)),
    'IconPixmap': DBusArray(DBusSignature('(iiay)'), const []),
    'OverlayIconName': DBusString(''),
    'OverlayIconPixmap': DBusArray(DBusSignature('(iiay)'), const []),
    'AttentionIconName': DBusString('dialog-warning-symbolic'),
    'AttentionIconPixmap': DBusArray(DBusSignature('(iiay)'), const []),
    'AttentionMovieName': DBusString(''),
    'ToolTip': DBusStruct([
      DBusString(trayIconFor(_tray.state)),
      DBusArray(DBusSignature('(iiay)'), const []),
      DBusString(trayTitleFor(_tray.state)),
      DBusString('Click to open. Menu: start or stop dictation.'),
    ]),
    'ItemIsMenu': DBusBoolean(false),
    'Menu': DBusObjectPath(StatusNotifierTray.menuPath),
  };

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      _iface,
      methods: [
        for (final m in ['ContextMenu', 'Activate', 'SecondaryActivate'])
          DBusIntrospectMethod(
            m,
            args: [
              DBusIntrospectArgument(
                DBusSignature('i'),
                DBusArgumentDirection.in_,
                name: 'x',
              ),
              DBusIntrospectArgument(
                DBusSignature('i'),
                DBusArgumentDirection.in_,
                name: 'y',
              ),
            ],
          ),
      ],
      signals: [
        DBusIntrospectSignal('NewIcon'),
        DBusIntrospectSignal('NewTitle'),
        DBusIntrospectSignal('NewToolTip'),
        DBusIntrospectSignal(
          'NewStatus',
          args: [
            DBusIntrospectArgument(
              DBusSignature('s'),
              DBusArgumentDirection.out,
            ),
          ],
        ),
      ],
      properties: [
        for (final e in _props.entries)
          DBusIntrospectProperty(
            e.key,
            e.value.signature,
            access: DBusPropertyAccess.read,
          ),
      ],
    ),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != _iface)
      return DBusMethodErrorResponse.unknownInterface();
    switch (call.name) {
      case 'Activate':
        _onActivate();
        return DBusMethodSuccessResponse();
      case 'ContextMenu':
      case 'SecondaryActivate':
      case 'Scroll':
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final v = interface == _iface ? _props[name] : null;
    return v == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(v);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(interface == _iface ? _props : {});
}

class _TrayMenuObject extends DBusObject {
  _TrayMenuObject(this._tray, this._actions)
    : super(DBusObjectPath(StatusNotifierTray.menuPath));
  final StatusNotifierTray _tray;
  final Map<TrayMenuItem, void Function()> _actions;
  int _revision = 1;

  static const _iface = 'com.canonical.dbusmenu';

  Map<String, DBusValue> get _props => {
    'Version': DBusUint32(3),
    'TextDirection': DBusString('ltr'),
    'Status': DBusString('normal'),
    'IconThemePath': DBusArray.string(const []),
  };

  Future<void> layoutChanged() {
    _revision++;
    return emitSignal(_iface, 'LayoutUpdated', [
      DBusUint32(_revision),
      DBusInt32(0),
    ]);
  }

  Map<String, DBusValue> _itemProps(int id) {
    final layout = buildMenuLayout(_tray.state);
    for (final child in layout.children[2].asArray()) {
      final s = child.asVariant().asStruct();
      if (s[0].asInt32() == id) return s[1].asStringVariantDict();
    }
    return {};
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != _iface)
      return DBusMethodErrorResponse.unknownInterface();
    switch (call.name) {
      case 'GetLayout':
        return DBusMethodSuccessResponse([
          DBusUint32(_revision),
          buildMenuLayout(_tray.state),
        ]);
      case 'GetGroupProperties':
        final ids = call.values[0].asInt32Array().toList();
        final wanted = ids.isEmpty
            ? [0, ...TrayMenuItem.values.map((e) => e.id)]
            : ids;
        return DBusMethodSuccessResponse([
          DBusArray(DBusSignature('(ia{sv})'), [
            for (final id in wanted)
              DBusStruct([
                DBusInt32(id),
                DBusDict.stringVariant(id == 0 ? {} : _itemProps(id)),
              ]),
          ]),
        ]);
      case 'GetProperty':
        final v = _itemProps(
          call.values[0].asInt32(),
        )[call.values[1].asString()];
        return v == null
            ? DBusMethodErrorResponse.invalidArgs()
            : DBusMethodSuccessResponse([DBusVariant(v)]);
      case 'Event':
        _dispatch(call.values[0].asInt32(), call.values[1].asString());
        return DBusMethodSuccessResponse();
      case 'EventGroup':
        for (final e in call.values[0].asArray()) {
          final s = e.asStruct();
          _dispatch(s[0].asInt32(), s[1].asString());
        }
        return DBusMethodSuccessResponse([
          DBusArray(DBusSignature('i'), const []),
        ]);
      case 'AboutToShow':
        return DBusMethodSuccessResponse([DBusBoolean(false)]);
      case 'AboutToShowGroup':
        return DBusMethodSuccessResponse([
          DBusArray(DBusSignature('i'), const []),
          DBusArray(DBusSignature('i'), const []),
        ]);
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  void _dispatch(int id, String event) {
    if (event != 'clicked') return;
    for (final item in TrayMenuItem.values) {
      if (item.id == id) _actions[item]?.call();
    }
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final v = interface == _iface ? _props[name] : null;
    return v == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(v);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(interface == _iface ? _props : {});
}
