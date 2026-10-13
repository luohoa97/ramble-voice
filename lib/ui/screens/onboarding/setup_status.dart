// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/cleanup/cleanup_engine.dart';
import '../../../core/models/model_downloader.dart';
import '../../../core/settings/app_settings.dart';
import '../../../platform/android/android_system.dart';
import '../../../platform/platform_services.dart';
import '../../util/hotkey_state.dart';
import '../../util/platform_flags.dart';

final androidSystemProvider = Provider<AndroidSystem>((ref) => AndroidSystem());

/// `Build.MANUFACTURER`, lower case.
final manufacturerProvider = FutureProvider<String>((ref) => ref.watch(androidSystemProvider).manufacturer());

/// Android API level (0 when unknown).
final androidSdkProvider = FutureProvider<int>((ref) => ref.watch(androidSystemProvider).sdkInt());

/// What the device can already do, for the setup guide and its banner.
class SetupStatus {
  const SetupStatus({
    this.micGranted = false,
    this.engineReady = false,
    this.keyboardEnabled = false,
    this.bubbleEnabled = false,
    this.ignoringBattery = false,
    this.hotkeyBound = false,
  });

  final bool micGranted;
  final bool engineReady;
  final bool keyboardEnabled;
  final bool bubbleEnabled;
  final bool ignoringBattery;
  final bool hotkeyBound;
}

/// Checked once per read; the guide invalidates it while it is open.
final setupStatusProvider = FutureProvider.autoDispose<SetupStatus>((ref) async {
  final services = ref.read(platformServicesProvider);
  final settings = ref.read(settingsProvider);
  final android = ref.read(isAndroidProvider);

  Future<bool> guard(Future<bool> f) async {
    try {
      return await f;
    } catch (_) {
      return false;
    }
  }

  final mic = await guard(services.audio.hasPermission());
  final bool engine;
  if (settings.engine == EngineKind.onDevice) {
    engine = ref.read(modelDownloaderProvider).statusOf(settings.gemmaVariant) is Downloaded;
  } else {
    try {
      engine = await services.secrets.geminiKeySource() != KeySource.none;
    } catch (_) {
      return SetupStatus(micGranted: mic);
    }
  }
  var keyboard = false, bubble = false, battery = false;
  if (android) {
    final system = ref.read(androidSystemProvider);
    keyboard = await guard(system.isKeyboardEnabled());
    bubble = await guard(system.isBubbleEnabled());
    battery = await guard(system.isIgnoringBattery());
  }
  final hotkey = ref.read(hotkeyStatusProvider);
  return SetupStatus(
    micGranted: mic,
    engineReady: engine,
    keyboardEnabled: keyboard,
    bubbleEnabled: bubble,
    ignoringBattery: battery,
    hotkeyBound: hotkey != null && hotkey.backend != HotkeyBackend.none,
  );
});

/// Step ids in order.
List<String> setupStepsFor({required bool android}) => android
    ? const ['welcome', 'mic', 'engine', 'keyboard', 'bubble', 'try', 'tips']
    : const ['welcome', 'hotkey', 'typing', 'tray', 'try'];

/// Steps whose completion the device can tell us.
bool detected(String id, SetupStatus? s) => s != null &&
    switch (id) {
      'mic' => s.micGranted,
      'engine' => s.engineReady,
      'keyboard' => s.keyboardEnabled,
      'bubble' => s.bubbleEnabled,
      'hotkey' => s.hotkeyBound,
      _ => false,
    };

bool stepDone(String id, SetupStatus? s, Set<String> persisted) => persisted.contains(id) || detected(id, s);

int stepsLeft(List<String> steps, SetupStatus? s, Set<String> persisted) =>
    steps.where((id) => !stepDone(id, s, persisted)).length;
