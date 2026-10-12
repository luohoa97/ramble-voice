// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3ELoadingIndicator;
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/cleanup/cleanup_engine.dart';
import '../../../core/cleanup/gemini/gemini_models.dart';
import '../../../core/settings/app_settings.dart';
import '../../util/open_url.dart';
import '../../util/platform_flags.dart';
import '../../widgets/notice_banner.dart';

const geminiFreeTierWarning = 'Free-tier requests may be used by Google to improve its products.';

String keySourceText(KeySource s) => switch (s) {
      KeySource.none => 'No key saved',
      KeySource.secureStorage => 'Key saved in secure storage on this device',
      KeySource.environment => 'Key in use: from GEMINI_API_KEY environment',
    };

final geminiKeySourceProvider = FutureProvider.autoDispose<KeySource>(
  (ref) => ref.watch(platformServicesProvider).secrets.geminiKeySource(),
);

final geminiModelsProvider = FutureProvider.autoDispose<List<GeminiModelInfo>>((ref) {
  ref.watch(geminiKeySourceProvider);
  return ref.watch(geminiEngineProvider).availableModels();
});

class GeminiSection extends ConsumerStatefulWidget {
  const GeminiSection({super.key, this.showStyleGuide = true});

  final bool showStyleGuide;

  @override
  ConsumerState<GeminiSection> createState() => _GeminiSectionState();
}

class _GeminiSectionState extends ConsumerState<GeminiSection> {
  final _key = TextEditingController();
  bool _obscure = true;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(geminiKeySourceProvider);
    ref.invalidate(geminiModelsProvider);
    ref.invalidate(activeEngineReadinessProvider);
    ref.read(geminiModelCacheProvider).invalidate();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) setState(() => _key.text = text);
  }

  Future<void> _save() async {
    final value = _key.text.trim();
    if (value.isEmpty) return;
    await ref.read(platformServicesProvider).secrets.writeGeminiKey(value);
    _key.clear();
    setState(() {
      _testResult = 'Key saved.';
      _testOk = true;
    });
    _refresh();
  }

  Future<void> _remove() async {
    await ref.read(platformServicesProvider).secrets.deleteGeminiKey();
    setState(() => _testResult = null);
    _refresh();
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      if (_key.text.trim().isNotEmpty) await _save();
      final model = await ref.read(geminiEngineProvider).testKey();
      if (!mounted) return;
      setState(() {
        _testResult = 'Key works. Using $model.';
        _testOk = true;
      });
      _refresh();
    } on CleanupFailure catch (f) {
      if (mounted) {
        setState(() {
          _testResult = f.message;
          _testOk = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _testResult = 'The key could not be tested. Check your connection.';
          _testOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final source = ref.watch(geminiKeySourceProvider).value ?? KeySource.none;
    final settings = ref.watch(settingsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const NoticeBanner(message: geminiFreeTierWarning, tone: NoticeTone.warning),
        const SizedBox(height: 16),
        if (widget.showStyleGuide) ...[
          Semantics(header: true, child: Text('Get an API key', style: t.titleMedium)),
          const SizedBox(height: 8),
          const _Step(1, 'Go to aistudio.google.com'),
          const _Step(2, 'Sign in with a Google account'),
          const _Step(3, 'Click "Get API key"'),
          const _Step(4, 'Create a key'),
          const _Step(5, 'Paste it here'),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.tonalIcon(
              onPressed: () => openUrl(geminiConsoleUrl),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('Open aistudio.google.com'),
            ),
          ),
          const SizedBox(height: 20),
        ],
        Text(keySourceText(source), style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
        const SizedBox(height: 8),
        TextField(
          controller: _key,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          decoration: InputDecoration(
            labelText: 'Gemini API key',
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: _obscure ? 'Show key' : 'Hide key',
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
                IconButton(
                  tooltip: 'Paste key',
                  icon: const Icon(Icons.content_paste_rounded),
                  onPressed: _paste,
                ),
              ],
            ),
          ),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton(onPressed: _save, child: const Text('Save key')),
            OutlinedButton(
              onPressed: _testing ? null : _test,
              child: const Text('Test key'),
            ),
            if (source == KeySource.secureStorage)
              TextButton(onPressed: _remove, child: const Text('Remove key')),
            if (_testing) M3ELoadingIndicator(size: 32, color: c.primary, semanticLabel: 'Testing key'),
          ],
        ),
        if (_testResult != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(_testResult!, style: t.bodyMedium?.copyWith(color: _testOk ? c.primary : c.error)),
          ),
        ],
        const SizedBox(height: 20),
        _ModelPicker(selected: settings.geminiModel, hasKey: source != KeySource.none),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('If Gemini is unavailable, use the on-device model'),
          value: settings.fallbackToOnDevice,
          onChanged: (v) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(fallbackToOnDevice: v)),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.text);
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Text('$n.', style: t.bodyLarge?.copyWith(color: c.primary)),
          ),
          Expanded(child: Text(text, style: t.bodyLarge)),
        ],
      ),
    );
  }
}

class _ModelPicker extends ConsumerWidget {
  const _ModelPicker({required this.selected, required this.hasKey});

  final String? selected;
  final bool hasKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    if (!hasKey) {
      return Text('Add a key to choose a model.', style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant));
    }
    final models = ref.watch(geminiModelsProvider);
    return models.when(
      loading: () => const LinearProgressIndicator(semanticsLabel: 'Loading models'),
      error: (e, _) => Text(
        e is CleanupFailure ? e.message : 'The model list could not be loaded.',
        style: t.bodyMedium?.copyWith(color: c.error),
      ),
      data: (list) {
        final current = list.any((m) => m.id == selected) ? selected : null;
        return DropdownMenu<String?>(
          key: ValueKey(current),
          width: 360,
          label: const Text('Gemini model'),
          initialSelection: current,
          dropdownMenuEntries: [
            const DropdownMenuEntry<String?>(value: null, label: 'Newest stable (automatic)'),
            for (final m in list) DropdownMenuEntry<String?>(value: m.id, label: m.preview ? '${m.id} (preview)' : m.id),
          ],
          onSelected: (id) {
            ref.read(settingsProvider.notifier).update((s) => s.copyWith(geminiModel: () => id));
            ref.invalidate(activeEngineReadinessProvider);
          },
        );
      },
    );
  }
}
