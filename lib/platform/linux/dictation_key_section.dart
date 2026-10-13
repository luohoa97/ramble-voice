// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../platform_services.dart';
import 'evdev_hotkey.dart';

/// Settings control for the Linux dictation key. Stateless: the owner saves
/// [value] (`capslock` | `portal`) and re-binds in [onChanged], then passes
/// the new [status].
class DictationKeySection extends StatelessWidget {
  const DictationKeySection({
    super.key,
    required this.value,
    required this.status,
    required this.onChanged,
  });

  final String value;
  final HotkeyStatus? status;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = status;
    final needsPermission =
        value == 'capslock' && s != null && s.backend != HotkeyBackend.evdev;
    final text = switch (s) {
      null => 'Checking...',
      _ when s.backend == HotkeyBackend.evdev =>
        'Caps Lock is active. Hold it to talk.',
      _ when s.message != null => s.message!,
      _ when s.trigger != null => 'Shortcut: ${s.trigger}',
      _ => 'No key is active',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Dictation key', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'capslock',
              label: Text('Caps Lock (hold to talk)'),
            ),
            ButtonSegment(value: 'portal', label: Text('Desktop shortcut')),
          ],
          selected: {value},
          onSelectionChanged: (v) => onChanged(v.first),
        ),
        const SizedBox(height: 8),
        Text(text, style: Theme.of(context).textTheme.bodyMedium),
        if (needsPermission && text == evdevPermissionMessage)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text(evdevPermissionCommand),
              onPressed: () => Clipboard.setData(
                const ClipboardData(text: evdevPermissionCommand),
              ),
            ),
          ),
      ],
    );
  }
}
