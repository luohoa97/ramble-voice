// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/cleanup/cleanup_engine.dart';
import '../../../core/cleanup/gemini/gemini_models.dart';
import 'gemini_section.dart';

const geminiModelNote =
    'Bigger models are more accurate but slower. If a model is busy, Ramble tries the next one, then on-device.';

/// Every audio-capable Gemini model, grouped by tier (Pro, Flash, Flash-Lite),
/// newest first. The first row is the automatic choice.
class GeminiModelPicker extends ConsumerWidget {
  const GeminiModelPicker({
    super.key,
    required this.selected,
    required this.hasKey,
  });

  final String? selected;
  final bool hasKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    if (!hasKey) {
      return Text(
        'Add a key to choose a model.',
        style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
      );
    }
    final models = ref.watch(geminiModelsProvider);
    return models.when(
      loading: () =>
          const LinearProgressIndicator(semanticsLabel: 'Loading models'),
      error: (e, _) => Text(
        e is CleanupFailure ? e.message : 'The model list could not be loaded.',
        style: t.bodyMedium?.copyWith(color: c.error),
      ),
      data: (list) {
        final current = list.any((m) => m.id == selected) ? selected : null;
        final defaultId = GeminiModelSelector.defaultModel(list)?.id;
        void pick(String? id) {
          ref
              .read(settingsProvider.notifier)
              .update((s) => s.copyWith(geminiModel: () => id));
          ref.invalidate(activeEngineReadinessProvider);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Gemini model', style: t.titleSmall),
            const SizedBox(height: 4),
            Text(
              geminiModelNote,
              style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            _ModelRow(
              title: 'Automatic (fastest working Flash)',
              subtitle: defaultId,
              selected: current == null,
              onTap: () => pick(null),
            ),
            for (final family in GeminiFamily.values) ...[
              if (list.any((m) => m.family == family && !m.alias))
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
                  child: Text(
                    family.label,
                    style: t.labelLarge?.copyWith(color: c.onSurfaceVariant),
                  ),
                ),
              for (final m in list.where((m) => m.family == family && !m.alias))
                _ModelRow(
                  title:
                      '${family.label} ${m.major}.${m.minor}${m.preview ? ' preview' : ''}',
                  subtitle: m.id,
                  selected: current == m.id,
                  isDefault: m.id == defaultId,
                  warning: m.freeTierUnavailable
                      ? 'Not on your free tier'
                      : m.unavailableReason,
                  health: m.healthLabel,
                  onTap: () => pick(m.id),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.isDefault = false,
    this.warning,
    this.health,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final bool isDefault;
  final String? warning;
  final String? health;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? c.primary : c.outline,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(title, style: t.bodyLarge),
                          if (isDefault)
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: c.primaryContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                child: Text(
                                  'Default',
                                  style: t.labelSmall?.copyWith(
                                    color: c.onPrimaryContainer,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: t.bodySmall?.copyWith(
                            color: c.onSurfaceVariant,
                          ),
                        ),
                      if (health != null)
                        Text(
                          health!,
                          style: t.bodySmall?.copyWith(
                            color: c.onSurfaceVariant,
                          ),
                        ),
                      if (warning != null)
                        Text(
                          warning!,
                          style: t.bodySmall?.copyWith(color: c.error),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
