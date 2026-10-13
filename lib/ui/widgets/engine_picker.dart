// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../core/cleanup/cleanup_engine.dart';
import '../screens/settings/gemini_section.dart';
import '../screens/settings/model_section.dart';
import '../theme/app_theme.dart';
import '../util/platform_flags.dart';
import 'adaptive_sheet.dart';

const engineTitles = {
  EngineKind.onDevice: 'On-device',
  EngineKind.gemini: 'Gemini cloud',
};

const engineTaglines = {
  EngineKind.onDevice: 'Private and free. Works offline.',
  EngineKind.gemini: 'Smarter cleanup. Needs internet and your own key.',
};

const engineIcons = {
  EngineKind.onDevice: Icons.memory_rounded,
  EngineKind.gemini: Icons.cloud_outlined,
};

/// Choose the engine, then its model, in one place. The two engines are
/// large radio rows; the selected one opens its own options right below it.
class EnginePicker extends ConsumerWidget {
  const EnginePicker({
    super.key,
    this.inset = Space.gutter,
    this.showPath = false,
  });

  /// Side inset of the two engine rows (the model rows pad themselves).
  final double inset;

  /// Show where model files are stored (desktop settings only).
  final bool showPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(settingsProvider.select((s) => s.engine));
    final isLinux = ref.watch(isLinuxProvider);

    void choose(EngineKind kind) => ref
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(engine: kind));

    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            child: EngineOption(
              kind: EngineKind.onDevice,
              selected: engine == EngineKind.onDevice,
              onTap: () => choose(EngineKind.onDevice),
            ),
          ),
          _Reveal(
            open: engine == EngineKind.onDevice,
            child: ModelChoices(showPath: showPath && isLinux),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            child: EngineOption(
              kind: EngineKind.gemini,
              selected: engine == EngineKind.gemini,
              onTap: () => choose(EngineKind.gemini),
            ),
          ),
          _Reveal(
            open: engine == EngineKind.gemini,
            child: const GeminiOptions(),
          ),
        ],
      ),
    );
  }
}

/// Slides the selected engine's options open and the other's closed.
class _Reveal extends StatelessWidget {
  const _Reveal({required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: Motion.of(context, Motion.medium),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: open
          ? Padding(padding: const EdgeInsets.only(top: 8), child: child)
          : const SizedBox(width: double.infinity),
    );
  }
}

/// One large selectable engine row: filled tonal container, check and a
/// heavier label when selected.
class EngineOption extends StatelessWidget {
  const EngineOption({
    super.key,
    required this.kind,
    required this.selected,
    required this.onTap,
  });

  final EngineKind kind;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final title = engineTitles[kind]!;
    final tagline = engineTaglines[kind]!;
    final bg = selected ? c.secondaryContainer : c.surfaceContainerHighest;
    final fg = selected ? c.onSecondaryContainer : c.onSurface;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      label: title,
      hint: tagline,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Shapes.extraLarge),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 80),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  Icon(
                    engineIcons[kind],
                    size: 28,
                    color: selected
                        ? c.onSecondaryContainer
                        : c.onSurfaceVariant,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: t.titleLarge?.copyWith(
                            color: fg,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            fontVariations: [
                              FontVariation('wght', selected ? 700 : 500),
                              const FontVariation('opsz', 22),
                            ],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tagline,
                          style: t.bodyMedium?.copyWith(
                            color: selected ? fg : c.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  AnimatedSwitcher(
                    duration: Motion.of(context, Motion.short),
                    child: Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      key: ValueKey(selected),
                      color: selected ? c.primary : c.outline,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens [EnginePicker] as a bottom sheet (phone) or dialog (desktop).
Future<void> showEnginePicker(BuildContext context) {
  return showAdaptiveSheet<void>(
    context,
    builder: (context) => SheetBody(
      title: 'Engine',
      footer: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ),
      children: const [EnginePicker(inset: 0)],
    ),
  );
}
