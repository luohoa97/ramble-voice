// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import '../../core/dictation/dictation_controller.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';

/// "1:00 left" warning shown when a recording nears its limit.
class LimitChip extends StatelessWidget {
  const LimitChip({super.key, required this.state});

  final DictationListening state;

  static String textFor(DictationListening s) =>
      '${formatClock(s.remaining)} left';

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final text = textFor(state);
    return Semantics(
      liveRegion: true,
      label: 'Recording stops automatically in $text',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.tertiaryContainer,
          borderRadius: BorderRadius.circular(100),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.timer_outlined,
                size: 18,
                color: c.onTertiaryContainer,
              ),
              const SizedBox(width: 6),
              Text(
                text,
                style: RambleTextStyles.of(context).timer
                    .copyWith(fontSize: 14, color: c.onTertiaryContainer),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
