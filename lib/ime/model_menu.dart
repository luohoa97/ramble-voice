// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../core/cleanup/cleanup_engine.dart';
import '../core/cleanup/gemini/gemini_models.dart';
import '../core/models/model_downloader.dart';
import '../core/settings/app_settings.dart';
import '../ui/screens/settings/gemini_section.dart';
import '../ui/widgets/engine_chip.dart';

/// Which panel, if any, replaces the keyboard's mic area: the engine picker
/// or the tone picker. Panels live inside the keyboard; a floating menu would
/// cover the keyboard and the app.
enum KeyboardPanel { none, model, tone }

class KeyboardPanelNotifier extends Notifier<KeyboardPanel> {
  @override
  KeyboardPanel build() => KeyboardPanel.none;

  void show(KeyboardPanel panel) => state = panel;

  /// Opens [panel], or closes it when it is already open.
  void toggle(KeyboardPanel panel) => state = state == panel ? KeyboardPanel.none : panel;

  void close() => state = KeyboardPanel.none;
}

final keyboardPanelProvider = NotifierProvider<KeyboardPanelNotifier, KeyboardPanel>(KeyboardPanelNotifier.new);

/// The engine chip in the keyboard's top bar. Tapping it opens [ModelPanel]
/// in place of the mic, inside the keyboard (a floating menu would cover the
/// keyboard and the app); tapping it again closes it.
class ModelMenu extends ConsumerWidget {
  const ModelMenu({super.key, this.onTick});

  final VoidCallback? onTick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep the lists warm so the panel opens with content.
    ref.watch(geminiKeySourceProvider);
    ref.watch(geminiModelsProvider);
    return EngineChip(
      onTap: () {
        onTick?.call();
        ref.read(keyboardPanelProvider.notifier).toggle(KeyboardPanel.model);
      },
    );
  }
}

/// Picks on-device Gemma or any Gemini model without leaving the keyboard:
/// a titled panel with a close button and one list of radio rows, grouped by
/// engine. A choice is saved at once and closes the panel.
class ModelPanel extends ConsumerStatefulWidget {
  const ModelPanel({super.key, this.onTick});

  final VoidCallback? onTick;

  @override
  ConsumerState<ModelPanel> createState() => _ModelPanelState();
}

class _ModelPanelState extends ConsumerState<ModelPanel> {
  @override
  void initState() {
    super.initState();
    // The app may have downloaded a model since the keyboard last looked.
    unawaited(_refreshDownloads());
  }

  Future<void> _refreshDownloads() async {
    final downloads = ref.read(modelDownloaderProvider);
    for (final v in ref.read(availableVariantsProvider)) {
      await downloads.refresh(v);
    }
    if (mounted) setState(() {});
  }

  void _close() => ref.read(keyboardPanelProvider.notifier).close();

  void _apply(String value) {
    widget.onTick?.call();
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
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final downloads = ref.read(modelDownloaderProvider);
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final c = theme.colorScheme;
    final onDevice = settings.engine == EngineKind.onDevice;
    final selected = onDevice
        ? 'gemma:${settings.gemmaVariantId}'
        : settings.geminiModel == null
            ? 'gemini:auto'
            : 'gemini:${settings.geminiModel}';

    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(text, style: t.labelLarge?.copyWith(color: c.primary)),
        );

    Widget row(String value, String title, {String? subtitle, bool enabled = true}) => RadioListTile<String>(
          value: value,
          dense: true,
          enabled: enabled,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
        );

    final rows = <Widget>[
      header('On-device'),
      for (final v in ref.watch(availableVariantsProvider))
        row(
          'gemma:${v.id}',
          v.label,
          subtitle: downloads.statusOf(v) is Downloaded ? 'Private, offline' : 'Not downloaded · download it in Settings',
          enabled: downloads.statusOf(v) is Downloaded,
        ),
      header('Gemini'),
    ];

    final source = ref.watch(geminiKeySourceProvider);
    final models = ref.watch(geminiModelsProvider);
    if (source.hasValue && source.requireValue == KeySource.none) {
      rows.add(const ListTile(dense: true, title: Text('Add a Gemini key in Settings')));
    } else if (models.isLoading || !models.hasValue) {
      rows.add(const ListTile(
        dense: true,
        leading: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        title: Text('Loading models'),
      ));
    } else {
      rows.add(row('gemini:auto', 'Automatic', subtitle: 'The fastest working Flash'));
      for (final family in [GeminiFamily.flash, GeminiFamily.flashLite, GeminiFamily.pro]) {
        for (final m in [for (final m in models.requireValue) if (m.family == family && !m.alias) m]) {
          rows.add(row(
            'gemini:${m.id}',
            '${family.label} ${m.major}.${m.minor}${m.preview ? ' preview' : ''}',
            subtitle: m.freeTierUnavailable ? 'Not on your free tier' : m.healthLabel,
            enabled: !m.unavailable,
          ));
        }
      }
    }

    return KeyboardPanelFrame(
      title: 'Engine and model',
      onClose: () {
        widget.onTick?.call();
        _close();
      },
      child: RadioGroup<String>(
        groupValue: selected,
        onChanged: (v) {
          if (v != null) _apply(v);
        },
        child: ListView(padding: const EdgeInsets.only(bottom: 8), children: rows),
      ),
    );
  }
}

/// The frame of an in-keyboard panel: a title, a close button and the body.
class KeyboardPanelFrame extends StatelessWidget {
  const KeyboardPanelFrame({super.key, required this.title, required this.onClose, required this.child});

  final String title;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Material(
      color: c.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SizedBox(
            height: 40,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(child: Semantics(header: true, child: Text(title, style: t.titleSmall))),
                IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: onClose),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
