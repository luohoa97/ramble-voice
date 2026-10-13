// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/settings/app_settings.dart';
import '../../../platform/android/android_system.dart';
import 'bubble_setup_panel.dart';

/// Settings for the Android floating mic: turn it on, the one-time sideload
/// step, size and the per-app blocklist. Android only; mount it inside a
/// settings card like the keyboard section.
class BubbleSection extends ConsumerStatefulWidget {
  const BubbleSection({super.key, this.system});

  /// Injected in tests.
  final AndroidSystem? system;

  @override
  ConsumerState<BubbleSection> createState() => _BubbleSectionState();
}

class _BubbleSectionState extends ConsumerState<BubbleSection>
    with WidgetsBindingObserver {
  late final AndroidSystem _system = widget.system ?? AndroidSystem();
  bool? _enabled;
  bool _batteryExempt = false;
  bool _secureGranted = false;
  bool _oem = false;
  bool _setupOpen = false;
  List<LaunchableApp> _apps = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
    unawaited(_loadApps());
    // The native service reads a mirror of these settings; keep it in sync.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _push(ref.read(settingsProvider)),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<void> _check() async {
    final v = await _system.isBubbleEnabled();
    final battery = await _system.isIgnoringBattery();
    final maker = await _system.manufacturer();
    final secure = await _system.hasSecureSettingsPermission();
    if (mounted) {
      setState(() {
        _enabled = v;
        _batteryExempt = battery;
        _secureGranted = secure;
        _oem = [
          'honor',
          'huawei',
          'xiaomi',
          'redmi',
          'poco',
        ].any(maker.contains);
      });
    }
  }

  Future<void> _loadApps() async {
    final apps = await _system.launchableApps();
    if (mounted) setState(() => _apps = apps);
  }

  void _push(AppSettings s) {
    unawaited(
      _system.setBubbleConfig(
        blockedApps: s.bubbleBlockedApps,
        size: s.bubbleSize.name,
        hotkeyEnabled: s.physicalKeyHotkey,
        hotkeyCode: s.physicalKeyCode,
      ),
    );
  }

  Future<void> _change(AppSettings Function(AppSettings) change) async {
    await ref.read(settingsProvider.notifier).update(change);
    _push(ref.read(settingsProvider));
  }

  static const _grantCommand =
      'adb shell pm grant io.github.luohoa97.ramblevoice android.permission.WRITE_SECURE_SETTINGS';

  String _label(String package) {
    for (final a in _apps) {
      if (a.packageName == package) return a.label;
    }
    return package;
  }

  Future<void> _pickHotkey() async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final code in const [
              BubbleHotkeys.capsLock,
              BubbleHotkeys.rightCtrl,
            ])
              ListTile(
                title: Text(BubbleHotkeys.label(code)),
                onTap: () => Navigator.of(context).pop(code),
              ),
            ListTile(
              leading: const Icon(Icons.fiber_manual_record_outlined),
              title: const Text('Record a key'),
              subtitle: const Text(
                'Press the key you want within 10 seconds. The floating mic must be on.',
              ),
              onTap: () => Navigator.of(context).pop(-1),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    var code = choice;
    if (choice == -1) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Press the key now')));
      }
      final recorded = await _system.recordHotkey();
      if (recorded == null) return;
      code = recorded;
    }
    await _change((s) => s.copyWith(physicalKeyCode: code));
  }

  Future<void> _addApp() async {
    final blocked = ref.read(settingsProvider).bubbleBlockedApps;
    final picked = await showModalBottomSheet<LaunchableApp>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _AppPicker(
        apps: [
          for (final a in _apps)
            if (!blocked.contains(a.packageName)) a,
        ],
      ),
    );
    if (picked != null)
      await _change(
        (s) => s.copyWith(
          bubbleBlockedApps: [...s.bubbleBlockedApps, picked.packageName],
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider);
    final enabled = _enabled ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Keep your usual keyboard. A small microphone handle docks to the edge of the screen whenever a keyboard is up. '
          'Tap it to dictate, hold it to talk, or drag it anywhere (it snaps to an edge). '
          'Your cleaned text is inserted where the cursor is.',
          style: t.bodyMedium,
        ),
        const SizedBox(height: 8),
        Text(
          _enabled == null
              ? 'Checking status'
              : (enabled ? 'Floating mic is on' : 'Floating mic is off'),
          style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.tonalIcon(
            onPressed: enabled
                ? _system.openBubbleSettings
                : () => setState(() => _setupOpen = true),
            icon: const Icon(Icons.mic_none_rounded),
            label: Text(
              enabled ? 'Floating mic settings' : 'Turn on floating mic',
            ),
          ),
        ),
        if (_setupOpen && !enabled) ...[
          const SizedBox(height: 12),
          BubbleSetupPanel(
            onDone: () {
              unawaited(_check());
              if (mounted) setState(() => _setupOpen = false);
            },
          ),
        ],
        if (!enabled) ...[
          const SizedBox(height: 16),
          Text('Installed outside the Play Store?', style: t.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Android blocks accessibility access for apps installed from a file until you allow it. Open App info, '
            'tap the three-dot menu, choose "Allow restricted settings", then come back and turn the floating mic on.',
            style: t.bodyMedium,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: _system.openAppDetails,
              icon: const Icon(Icons.info_outline_rounded),
              label: const Text('Open App info'),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          'Ramble Voice does not read or store screen content. It only sees the field you dictate into, to insert the text.',
          style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
        ),
        if (enabled)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () async {
                await _system.forgetBubble();
                await _system.openBubbleSettings();
              },
              child: const Text('Turn off floating mic'),
            ),
          ),
        const SizedBox(height: 16),
        Text('Keep the floating mic on', style: t.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Some phones switch accessibility apps off to save battery. If that happens, Ramble Voice shows a '
          'notification so you can turn the mic back on in one tap. These settings make it less likely.',
          style: t.bodyMedium,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: _batteryExempt
                ? null
                : () => _system.requestIgnoreBattery(),
            icon: Icon(
              _batteryExempt
                  ? Icons.check_rounded
                  : Icons.battery_saver_rounded,
            ),
            label: Text(
              _batteryExempt
                  ? 'Battery use is unrestricted'
                  : 'Allow unrestricted battery',
            ),
          ),
        ),
        if (_oem) ...[
          const SizedBox(height: 8),
          Text(
            'On Honor and Huawei phones, open the App launch manager, set Ramble Voice to "Manage manually" and '
            'allow auto-launch, secondary launch and run in background. On Xiaomi, turn on Autostart for Ramble Voice.',
            style: t.bodyMedium,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: _system.openOemAutostart,
              icon: const Icon(Icons.rocket_launch_outlined),
              label: const Text('Open App launch manager'),
            ),
          ),
        ],
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Auto-restore floating mic'),
          subtitle: const Text(
            "If Android or your phone's battery manager turns the floating mic off, Ramble turns it back on. "
            'To turn the floating mic off for good, turn off this switch first.',
          ),
          value: settings.bubbleAutoRestore,
          onChanged: (v) async {
            await _change((s) => s.copyWith(bubbleAutoRestore: v));
            await _system.setBubbleAutoRestore(v);
            unawaited(_check());
          },
        ),
        if (settings.bubbleAutoRestore) ...[
          Text(
            _secureGranted ? 'Permission granted. Auto-restore is active.' : 'Needs a one-time permission from a computer. With USB or wireless debugging connected, run:',
            style: t.bodyMedium?.copyWith(
              color: _secureGranted ? c.primary : c.onSurfaceVariant,
            ),
          ),
          if (!_secureGranted) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    _grantCommand,
                    style: t.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy command',
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () => Clipboard.setData(
                    const ClipboardData(text: _grantCommand),
                  ),
                ),
              ],
            ),
          ],
        ],
        const SizedBox(height: 16),
        Text('Size', style: t.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<BubbleSize>(
          segments: const [
            ButtonSegment(value: BubbleSize.small, label: Text('Small')),
            ButtonSegment(value: BubbleSize.medium, label: Text('Medium')),
          ],
          selected: {settings.bubbleSize},
          onSelectionChanged: (v) =>
              _change((s) => s.copyWith(bubbleSize: v.first)),
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Hardware keyboard key'),
          subtitle: Text(
            'Hold ${BubbleHotkeys.label(settings.physicalKeyCode)} on a physical keyboard to dictate. '
            'Only this one key is watched; no other keystrokes are read.',
          ),
          value: settings.physicalKeyHotkey,
          onChanged: (v) => _change((s) => s.copyWith(physicalKeyHotkey: v)),
        ),
        if (settings.physicalKeyHotkey)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _pickHotkey,
              icon: const Icon(Icons.keyboard_alt_outlined),
              label: Text(
                'Key: ${BubbleHotkeys.label(settings.physicalKeyCode)}',
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text('Hide in these apps', style: t.titleSmall),
        const SizedBox(height: 4),
        if (settings.bubbleBlockedApps.isEmpty)
          Text(
            'None. The mic shows in every app except password fields.',
            style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
          )
        else
          for (final package in settings.bubbleBlockedApps)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_label(package)),
              subtitle: _label(package) == package ? null : Text(package),
              trailing: IconButton(
                tooltip: 'Show in ${_label(package)} again',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => _change(
                  (s) => s.copyWith(
                    bubbleBlockedApps: [
                      ...s.bubbleBlockedApps.where((p) => p != package),
                    ],
                  ),
                ),
              ),
            ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: _apps.isEmpty ? null : _addApp,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Hide in an app'),
          ),
        ),
      ],
    );
  }
}

class _AppPicker extends StatefulWidget {
  const _AppPicker({required this.apps});

  final List<LaunchableApp> apps;

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final a in widget.apps)
        if (q.isEmpty ||
            a.label.toLowerCase().contains(q) ||
            a.packageName.toLowerCase().contains(q))
          a,
    ]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: TextField(
              autofocus: false,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search apps',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: shown.length,
              itemBuilder: (context, i) => ListTile(
                title: Text(shown[i].label),
                subtitle: Text(shown[i].packageName),
                onTap: () => Navigator.of(context).pop(shown[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
