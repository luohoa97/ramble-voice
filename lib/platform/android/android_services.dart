// SPDX-License-Identifier: GPL-3.0-or-later

/// Android [PlatformServices]: AudioRecord over a method channel, Keystore
/// backed secrets, clipboard (app) or InputConnection (keyboard) insertion.
library;

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/settings/app_settings.dart';
import '../platform_services.dart';
import 'android_audio_source.dart';
import 'android_system.dart';
import 'ime_bridge.dart';

export 'android_audio_source.dart';
export 'android_system.dart';
export 'ime_bridge.dart';

/// Builds the Android services.
///
/// In the app (default) text is copied to the clipboard and the microphone
/// permission can be requested. With [keyboard] set (the IME engine) text is
/// committed through [bridge] and permission prompts are skipped; the UI sends
/// the user to the app instead.
Future<PlatformServices> createAndroidServices({bool keyboard = false, ImeBridge? bridge}) async {
  final system = AndroidSystem();
  final ImeBridge? ime = keyboard ? (bridge ?? ImeBridge()) : null;
  return PlatformServices(
    audio: AndroidAudioSource(canRequestPermission: !keyboard),
    secrets: AndroidSecretStore(),
    inserter: AndroidTextInserter(ime),
    notifier: AndroidNotifier(),
    accentColor: system.accentColor,
    share: system.share,
    haptic: system.haptic,
  );
}

/// Gemini API key in the Android Keystore (flutter_secure_storage).
class AndroidSecretStore implements SecretStore {
  AndroidSecretStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static const _geminiKey = 'gemini_api_key';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> readGeminiKey() async {
    try {
      final v = (await _storage.read(key: _geminiKey))?.trim();
      return v == null || v.isEmpty ? null : v;
    } on PlatformException {
      // Unreadable (e.g. restored from a backup with a lost key): treat as unset.
      return null;
    }
  }

  @override
  Future<void> writeGeminiKey(String key) => _storage.write(key: _geminiKey, value: key.trim());

  @override
  Future<void> deleteGeminiKey() => _storage.delete(key: _geminiKey);

  @override
  Future<KeySource> geminiKeySource() async => await readGeminiKey() == null ? KeySource.none : KeySource.secureStorage;
}

/// Keyboard: types into the focused field. App: copies to the clipboard.
class AndroidTextInserter implements TextInserter {
  AndroidTextInserter([this._ime]);

  final ImeBridge? _ime;

  @override
  Future<InsertResult> insert(String text) async {
    final ime = _ime;
    if (ime != null && await ime.commitText(text)) {
      return const InsertResult(InsertMethod.typed, backend: 'InputConnection');
    }
    await copy(text);
    return InsertResult(
      InsertMethod.clipboardOnly,
      backend: 'Clipboard',
      message: ime == null ? null : 'No text field is focused. The text was copied.',
    );
  }

  @override
  Future<void> copy(String text) => Clipboard.setData(ClipboardData(text: text));

  @override
  Future<String> describe() async => _ime != null ? 'Keyboard (InputConnection)' : 'Clipboard';
}
