// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../screens/onboarding/setup_status.dart';
import '../theme/app_theme.dart';
import '../util/platform_flags.dart';

/// A slim "Finish setup (2 steps left)" line until the guide is done or the
/// user hides it.
class SetupBanner extends ConsumerWidget {
  const SetupBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    if (!settings.onboarded || settings.completedSetup.contains('dismissed')) return const SizedBox.shrink();
    final status = ref.watch(setupStatusProvider).value;
    if (status == null) return const SizedBox.shrink();
    final steps = setupStepsFor(android: ref.watch(isAndroidProvider));
    final left = stepsLeft(steps, status, settings.completedSetup);
    if (left == 0) return const SizedBox.shrink();
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final text = 'Finish setup ($left ${left == 1 ? 'step' : 'steps'} left)';
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.x1, Space.gutter, 0),
      child: Material(
        color: c.tertiaryContainer,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: text,
                child: InkWell(
                  onTap: () => context.push('/setup'),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 20),
                      child: Row(
                        children: [
                          Expanded(child: Text(text, style: t.labelLarge?.copyWith(color: c.onTertiaryContainer))),
                          Icon(Icons.chevron_right_rounded, color: c.onTertiaryContainer),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Hide setup reminder',
              icon: Icon(Icons.close_rounded, size: 20, color: c.onTertiaryContainer),
              onPressed: () => ref
                  .read(settingsProvider.notifier)
                  .update((s) => s.copyWith(completedSetup: {...s.completedSetup, 'dismissed'})),
            ),
          ],
        ),
      ),
    );
  }
}
