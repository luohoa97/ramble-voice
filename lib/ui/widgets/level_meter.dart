// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Row of bars that fill with input level (0..1).
class LevelMeter extends StatelessWidget {
  const LevelMeter({super.key, required this.level, this.bars = 16, this.height = 24});

  final double level;
  final int bars;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final lit = (math.sqrt(level.clamp(0.0, 1.0)) * bars).round();
    return Semantics(
      label: 'Input level',
      value: '${(level.clamp(0.0, 1.0) * 100).round()} percent',
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < bars; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 80),
                    width: 6,
                    height: height * (0.35 + 0.65 * (i + 1) / bars),
                    decoration: BoxDecoration(
                      color: i < lit ? c.primary : c.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
