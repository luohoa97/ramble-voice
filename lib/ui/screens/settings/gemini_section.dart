// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3ELoadingIndicator;
import 'package:material_ui/material_ui.dart';

import '../../../app/providers.dart';
import '../../../core/cleanup/cleanup_engine.dart';
import '../../../core/cleanup/gemini/gemini_models.dart';
import '../../../core/settings/app_settings.dart';
import '../../util/open_url.dart';
import 'gemini_model_picker.dart';
import '../../util/platform_flags.dart';

const geminiFreeTierWarning =
    'Free-tier requests may be used by Google to improve its products.';

String keySourceText(KeySource s) => switch (s) {
  KeySource.none => 'No key saved',
  KeySource.secureStorage => 'Saved in secure storage on this device',
  KeySource.environment => 'From the GEMINI_API_KEY environment variable',
};

final geminiKeySourceProvider = FutureProvider.autoDispose<KeySource>(
  (ref) => ref.watch(platformServicesProvider).secrets.geminiKeySource(),
);

final geminiModelsProvider = FutureProvider.autoDispose<List<GeminiModelInfo>>((
  ref,
) {
  ref.watch(geminiKeySourceProvider);
  return ref.watch(geminiEngineProvider).availableModels();
});

/// Everything Gemini needs, as flat rows: key, model, fallback switch, and
/// the free-tier note.
class GeminiOptions extends ConsumerStatefulWidget {
  const GeminiOptions({super.key});

  @override
  ConsumerState<GeminiOptions> createState() => _GeminiOptionsState();
}

class _GeminiOptionsState extends ConsumerState<GeminiOptions> {
  final _key = TextEditingController();
  bool _obscure = true;
  bool _editing = false;
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
      _editing = false;
      _testResult = 'Key saved.';
      _testOk = true;
    });
    _refresh();
  }

  Future<void> _remove() async {
    await ref.read(platformServicesProvider).secrets.deleteGeminiKey();
    setState(() {
      _testResult = null;
      _editing = false;
    });
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
    final hasKey = source != KeySource.none;
    final showField = !hasKey || _editing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: c.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  geminiFreeTierWarning,
                  style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        if (showField)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _key,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: InputDecoration(
                    labelText: 'Gemini API key',
                    helperText: keySourceText(source),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: _obscure ? 'Show key' : 'Hide key',
                          icon: Icon(
                            _obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
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
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton(
                      onPressed: _save,
                      child: const Text('Save key'),
                    ),
                    TextButton(
                      onPressed: _testing ? null : _test,
                      child: const Text('Test key'),
                    ),
                    TextButton.icon(
                      onPressed: () => openUrl(geminiConsoleUrl),
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('Get a key at aistudio.google.com'),
                    ),
                    if (hasKey)
                      TextButton(
                        onPressed: () => setState(() => _editing = false),
                        child: const Text('Cancel'),
                      ),
                  ],
                ),
              ],
            ),
          )
        else
          ListTile(
            contentPadding: const EdgeInsets.only(left: 16, right: 8),
            leading: Icon(Icons.key_rounded, color: c.onSurfaceVariant),
            title: const Text('API key'),
            subtitle: Text(
              source == KeySource.environment
                  ? keySourceText(source)
                  : 'Saved on this device',
              style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_testing)
                  M3ELoadingIndicator(
                    size: 32,
                    color: c.primary,
                    semanticLabel: 'Testing key',
                  )
                else
                  TextButton(onPressed: _test, child: const Text('Test')),
                if (source == KeySource.secureStorage)
                  PopupMenuButton<String>(
                    tooltip: 'Key options',
                    onSelected: (a) {
                      if (a == 'replace') setState(() => _editing = true);
                      if (a == 'remove') _remove();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'replace',
                        child: Text('Replace key'),
                      ),
                      PopupMenuItem(value: 'remove', child: Text('Remove key')),
                    ],
                  ),
              ],
            ),
          ),
        if (_testResult != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _testResult!,
                style: t.bodyMedium?.copyWith(
                  color: _testOk ? c.onSurfaceVariant : c.error,
                ),
              ),
            ),
          ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GeminiModelPicker(
            selected: settings.geminiModel,
            hasKey: hasKey,
          ),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: const EdgeInsets.only(left: 16, right: 8),
          title: const Text(
            'If Gemini is unavailable, use the on-device model',
          ),
          value: settings.fallbackToOnDevice,
          onChanged: (v) => ref
              .read(settingsProvider.notifier)
              .update((s) => s.copyWith(fallbackToOnDevice: v)),
        ),
      ],
    );
  }
}
