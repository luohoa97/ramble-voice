// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../core/cleanup/cleanup_engine.dart';
import '../core/cleanup/gemini/gemini_models.dart';
import '../core/models/model_catalog.dart';
import '../core/models/model_downloader.dart';
import '../core/settings/app_settings.dart';
import '../ui/screens/settings/gemini_section.dart';
import '../ui/widgets/engine_chip.dart';

/// The engine chip as an in-place dropdown: pick on-device Gemma or any Gemini
/// model without leaving the keyboard. Choices are saved at once.
class ModelMenu extends ConsumerStatefulWidget {
  const ModelMenu({super.key, this.onTick});

  final VoidCallback? onTick;

  @override
  ConsumerState<ModelMenu> createState() => _ModelMenuState();
}

class _ModelMenuState extends ConsumerState<ModelMenu> {
  final _key = GlobalKey<PopupMenuButtonState<String>>();

  void _apply(String value) {
    final notifier = ref.read(settingsProvider.notifier);
    if (value.startsWith('gemma:')) {
      final id = value.substring(6);
      notifier.update((s) => s.copyWith(engine: EngineKind.onDevice, gemmaVariantId: id));
    } else if (value == 'gemini:auto') {
      notifier.update((s) => s.copyWith(engine: EngineKind.gemini, geminiModel: () => null));
    } else if (value.startsWith('gemini:')) {
      final id = value.substring(7);
      notifier.update((s) => s.copyWith(engine: EngineKind.gemini, geminiModel: () => id));
    }
    ref.invalidate(activeEngineReadinessProvider);
  }

  List<PopupMenuEntry<String>> _items(BuildContext context) {
    final settings = ref.read(settingsProvider);
    final downloads = ref.read(modelDownloaderProvider);
    final t = Theme.of(context).textTheme;
    final onDevice = settings.engine == EngineKind.onDevice;

    PopupMenuEntry<String> header(String text) =>
        PopupMenuItem<String>(enabled: false, height: 32, child: Text(text, style: t.labelMedium));

    final items = <PopupMenuEntry<String>>[
      header('On-device'),
      for (final v in ModelCatalog.all)
        CheckedPopupMenuItem<String>(
          value: 'gemma:${v.id}',
          checked: onDevice && settings.gemmaVariantId == v.id,
          enabled: downloads.statusOf(v) is Downloaded,
          child: Text(downloads.statusOf(v) is Downloaded ? v.label : '${v.label} · Not downloaded'),
        ),
      const PopupMenuDivider(),
      header('Gemini'),
    ];

    final source = ref.read(geminiKeySourceProvider);
    final models = ref.read(geminiModelsProvider);
    if (source.hasValue && source.requireValue == KeySource.none) {
      items.add(const PopupMenuItem<String>(enabled: false, child: Text('Add a Gemini key in Settings')));
    } else if (models.isLoading || !models.hasValue) {
      items.add(const PopupMenuItem<String>(
        enabled: false,
        child: Row(children: [
          SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Text('Loading models'),
        ]),
      ));
    } else {
      final list = models.requireValue;
      items.add(CheckedPopupMenuItem<String>(
        value: 'gemini:auto',
        checked: !onDevice && settings.geminiModel == null,
        child: const Text('Automatic (fastest working Flash)'),
      ));
      for (final family in [GeminiFamily.flash, GeminiFamily.flashLite, GeminiFamily.pro]) {
        final group = [for (final m in list) if (m.family == family && !m.alias) m];
        if (group.isEmpty) continue;
        items.add(header(family.label));
        for (final m in group) {
          final note = m.freeTierUnavailable ? 'Not on your free tier' : m.healthLabel;
          items.add(CheckedPopupMenuItem<String>(
            value: 'gemini:${m.id}',
            checked: !onDevice && settings.geminiModel == m.id,
            enabled: !m.unavailable,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${m.major}.${m.minor}${m.preview ? ' preview' : ''}'),
                if (note != null) Text(note, style: t.bodySmall),
              ],
            ),
          ));
        }
      }
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    // Keep the lists warm so the menu opens with content.
    ref.watch(geminiKeySourceProvider);
    ref.watch(geminiModelsProvider);
    final height = MediaQuery.sizeOf(context).height;
    return PopupMenuButton<String>(
      key: _key,
      constraints: BoxConstraints(maxHeight: height - 16),
      tooltip: 'Engine and model',
      onSelected: _apply,
      itemBuilder: _items,
      child: EngineChip(
        onTap: () {
          widget.onTick?.call();
          _key.currentState?.showButtonMenu();
        },
      ),
    );
  }
}
