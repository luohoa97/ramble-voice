// SPDX-License-Identifier: GPL-3.0-or-later

/// Gemini API key storage over the freedesktop Secret Service API
/// (GNOME Keyring, KWallet 6, KeePassXC) using D-Bus only.
///
/// Precedence: the `GEMINI_API_KEY` environment variable, then the Secret
/// Service, then a fallback file. The fallback file (`<support>/gemini-api-key`,
/// mode 0600) is used only when no Secret Service is reachable (for example a
/// bare Sway session without a keyring daemon). It is NOT encrypted; the
/// Settings screen should show [describe] so users know where their key lives.
///
/// The "plain" session algorithm is used: secrets cross the local session bus
/// unencrypted, which is the same trust boundary as libsecret's own default on
/// most distributions and keeps the implementation free of crypto code.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';

import '../../core/settings/app_settings.dart';
import 'linux_environment.dart';

class SecretServiceStore implements SecretStore {
  SecretServiceStore(
    this._bus, {
    required this.fallbackFile,
    this.secretKey = 'gemini-api-key',
    Map<String, String>? environment,
    this.promptTimeout = const Duration(minutes: 2),
  }) : _env = environment ?? Platform.environment;

  static const _service = 'org.freedesktop.secrets';
  static const _serviceIface = 'org.freedesktop.Secret.Service';
  static const _collectionIface = 'org.freedesktop.Secret.Collection';
  static const _itemIface = 'org.freedesktop.Secret.Item';
  static const _promptIface = 'org.freedesktop.Secret.Prompt';
  static const _noObject = '/';

  final DBusClient _bus;
  final File fallbackFile;
  final String secretKey;
  final Duration promptTimeout;
  final Map<String, String> _env;

  /// Set once a Secret Service call failed because nothing provides it.
  bool _serviceMissing = false;

  Map<String, String> get _attributes => {
    'application': rambleAppId,
    'key': secretKey,
  };

  DBusRemoteObject get _root => DBusRemoteObject(
    _bus,
    name: _service,
    path: DBusObjectPath('/org/freedesktop/secrets'),
  );

  String? get _envKey {
    final v = _env['GEMINI_API_KEY']?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  // ---- SecretStore ------------------------------------------------------

  @override
  Future<String?> readGeminiKey() async {
    final fromEnv = _envKey;
    if (fromEnv != null) return fromEnv;
    final stored = await _readSecretService();
    return stored ?? await _readFile();
  }

  @override
  Future<void> writeGeminiKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return deleteGeminiKey();
    if (await _writeSecretService(trimmed)) {
      await _deleteFile(); // never keep a stale plaintext copy
    } else {
      await _writeFile(trimmed);
    }
  }

  @override
  Future<void> deleteGeminiKey() async {
    try {
      await _deleteSecretService();
    } catch (_) {}
    await _deleteFile();
  }

  @override
  Future<KeySource> geminiKeySource() async {
    if (_envKey != null) return KeySource.environment;
    if (await _readSecretService() != null || await _readFile() != null)
      return KeySource.secureStorage;
    return KeySource.none;
  }

  /// One line for the Settings screen describing where the key is kept.
  Future<String> describe() async {
    if (_envKey != null)
      return 'Using the GEMINI_API_KEY environment variable.';
    if (await _readSecretService() != null)
      return 'Stored in the system keyring (Secret Service).';
    if (await _readFile() != null) {
      return 'Stored in ${fallbackFile.path} (permissions 0600, not encrypted) because no keyring service was available. '
          'Install and unlock GNOME Keyring or KWallet to store it securely.';
    }
    return await _serviceAvailable()
        ? 'No key saved. It will be stored in the system keyring.'
        : 'No key saved. No keyring service was found, so it would be stored unencrypted in ${fallbackFile.path} (0600).';
  }

  Future<bool> _serviceAvailable() async {
    if (_serviceMissing) return false;
    try {
      return await _bus.getNameOwner(_service) != null ||
          (await _bus.listActivatableNames()).contains(_service);
    } catch (_) {
      return false;
    }
  }

  // ---- Secret Service ---------------------------------------------------

  Future<T?> _withSession<T>(
    Future<T?> Function(DBusObjectPath session) body,
  ) async {
    if (_serviceMissing) return null;
    DBusObjectPath session;
    try {
      final r = await _root
          .callMethod(_serviceIface, 'OpenSession', [
            DBusString('plain'),
            DBusVariant(DBusString('')),
          ])
          .timeout(const Duration(seconds: 5));
      session = r.returnValues[1].asObjectPath();
    } on DBusServiceUnknownException {
      _serviceMissing = true;
      return null;
    } on TimeoutException {
      _serviceMissing = true; // a bus that never answers is as good as absent
      return null;
    } on DBusMethodResponseException catch (e) {
      if (e.errorName.contains('ServiceUnknown') ||
          e.errorName.contains('NoReply') ||
          e.errorName.contains('NameHasNoOwner')) {
        _serviceMissing = true;
      }
      return null;
    } catch (_) {
      return null;
    }
    try {
      return await body(session);
    } catch (_) {
      return null;
    } finally {
      try {
        await DBusRemoteObject(
          _bus,
          name: _service,
          path: session,
        ).callMethod('org.freedesktop.Secret.Session', 'Close', const []);
      } catch (_) {}
    }
  }

  DBusDict _ssDict(Map<String, String> m) => DBusDict(
    DBusSignature('s'),
    DBusSignature('s'),
    {for (final e in m.entries) DBusString(e.key): DBusString(e.value)},
  );

  DBusRemoteObject _obj(DBusObjectPath p) =>
      DBusRemoteObject(_bus, name: _service, path: p);

  Future<List<DBusObjectPath>> _search() async {
    final r = await _root.callMethod(_serviceIface, 'SearchItems', [
      _ssDict(_attributes),
    ]);
    return [
      ...r.returnValues[0].asObjectPathArray(),
      ...r.returnValues[1].asObjectPathArray(),
    ];
  }

  /// Unlocks [objects] (collections or items), prompting the user if needed.
  Future<bool> _unlock(List<DBusObjectPath> objects) async {
    final r = await _root.callMethod(_serviceIface, 'Unlock', [
      DBusArray.objectPath(objects),
    ]);
    final unlocked = r.returnValues[0].asObjectPathArray().toSet();
    final prompt = r.returnValues[1].asObjectPath();
    if (prompt.value == _noObject) return objects.every(unlocked.contains);
    final dismissed = await _runPrompt(prompt);
    return !dismissed;
  }

  /// Shows a Secret Service prompt. Returns whether it was dismissed.
  Future<bool> _runPrompt(DBusObjectPath prompt) async {
    final done = Completer<bool>();
    final sub =
        DBusSignalStream(
          _bus,
          sender: _service,
          interface: _promptIface,
          name: 'Completed',
          path: prompt,
        ).listen((s) {
          if (!done.isCompleted) done.complete(s.values[0].asBoolean());
        });
    try {
      await Future<void>.delayed(Duration.zero);
      await _obj(prompt).callMethod(_promptIface, 'Prompt', [DBusString('')]);
      return await done.future.timeout(promptTimeout, onTimeout: () => true);
    } finally {
      await sub.cancel();
    }
  }

  Future<String?> _readSecretService() => _withSession<String>((session) async {
    final items = await _search();
    for (final item in items) {
      try {
        return await _getSecret(item, session);
      } on DBusMethodResponseException catch (e) {
        if (!e.errorName.endsWith('IsLocked')) rethrow;
        if (!await _unlock([item])) continue;
        return await _getSecret(item, session);
      }
    }
    return null;
  });

  Future<String> _getSecret(DBusObjectPath item, DBusObjectPath session) async {
    final r = await _obj(item).callMethod(_itemIface, 'GetSecret', [session]);
    final secret = r.returnValues[0].asStruct(); // (o, ay, ay, s)
    return utf8.decode(secret[2].asByteArray().toList());
  }

  Future<DBusObjectPath?> _defaultCollection() async {
    for (final alias in ['default', 'login']) {
      final r = await _root.callMethod(_serviceIface, 'ReadAlias', [
        DBusString(alias),
      ]);
      final p = r.returnValues[0].asObjectPath();
      if (p.value != _noObject) return p;
    }
    return null;
  }

  Future<bool> _writeSecretService(String key) async {
    final ok = await _withSession<bool>((session) async {
      final collection = await _defaultCollection();
      if (collection == null) return false;
      var locked = true;
      try {
        locked = (await _obj(
          collection,
        ).getProperty(_collectionIface, 'Locked')).asBoolean();
      } catch (_) {}
      if (locked && !await _unlock([collection])) return false;
      final r = await _obj(collection)
          .callMethod(_collectionIface, 'CreateItem', [
            DBusDict.stringVariant({
              '$_itemIface.Label': DBusString('Ramble Voice Gemini API key'),
              '$_itemIface.Attributes': _ssDict(_attributes),
            }),
            DBusStruct([
              session,
              DBusArray.byte(const []),
              DBusArray.byte(utf8.encode(key)),
              DBusString('text/plain; charset=utf8'),
            ]),
            DBusBoolean(true), // replace the item with the same attributes
          ]);
      final prompt = r.returnValues[1].asObjectPath();
      if (prompt.value != _noObject) return !await _runPrompt(prompt);
      return true;
    });
    return ok ?? false;
  }

  Future<void> _deleteSecretService() => _withSession<bool>((session) async {
    for (final item in await _search()) {
      final r = await _obj(item).callMethod(_itemIface, 'Delete', const []);
      final prompt = r.returnValues[0].asObjectPath();
      if (prompt.value != _noObject) await _runPrompt(prompt);
    }
    return true;
  });

  // ---- Fallback file ----------------------------------------------------

  Future<String?> _readFile() async {
    try {
      final v = (await fallbackFile.readAsString()).trim();
      return v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeFile(String key) async {
    await fallbackFile.parent.create(recursive: true);
    // Create with restrictive permissions before the secret is written.
    if (!await fallbackFile.exists()) {
      await fallbackFile.create();
    }
    await Process.run('chmod', ['600', fallbackFile.path]);
    await fallbackFile.writeAsString(key, flush: true);
  }

  Future<void> _deleteFile() async {
    try {
      if (await fallbackFile.exists()) await fallbackFile.delete();
    } catch (_) {}
  }
}
