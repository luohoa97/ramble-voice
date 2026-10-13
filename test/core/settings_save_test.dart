// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/app/providers.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';

void main() {
  test('overlapping saves leave the latest settings on disk', () async {
    final dir = await Directory.systemTemp.createTemp('ramble_settings');
    addTearDown(() => dir.delete(recursive: true));
    final store = SettingsStore(File('${dir.path}/settings.json'));
    final container = ProviderContainer(overrides: [
      initialSettingsProvider.overrideWithValue(const AppSettings()),
      settingsStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);
    final n = container.read(settingsProvider.notifier);
    // Finishing setup: a step is marked done and setup is finished at once.
    final a = n.update((s) => s.copyWith(completedSetup: {...s.completedSetup, 'tips'}));
    final b = n.update((s) => s.copyWith(onboarded: true));
    await Future.wait([a, b]);
    final saved = await store.load();
    expect(saved.onboarded, isTrue);
    expect(saved.completedSetup, contains('tips'));
    expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
  });

  test('a corrupt settings file falls back to the last good copy, not defaults', () async {
    final dir = await Directory.systemTemp.createTemp('ramble_settings');
    addTearDown(() => dir.delete(recursive: true));
    final store = SettingsStore(File('${dir.path}/settings.json'));
    await store.save(const AppSettings(onboarded: true));
    await store.save(const AppSettings(onboarded: true, usageLog: false));
    await store.file.writeAsString('{"onboard');
    final loaded = await store.load();
    expect(loaded.onboarded, isTrue);
  });
}
