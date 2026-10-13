// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../ui/screens/onboarding_screen.dart';
import '../ui/screens/settings_screen.dart';
import '../ui/shell.dart';
import 'providers.dart';

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');
final _shellKey = GlobalKey<NavigatorState>(debugLabel: 'shell');

GoRouter buildRouter({required ValueListenable<bool> onboarded}) {
  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/',
    refreshListenable: onboarded,
    redirect: (context, state) {
      final done = onboarded.value;
      final atOnboarding = state.matchedLocation == '/onboarding';
      if (!done && !atOnboarding) return '/onboarding';
      if (done && atOnboarding) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
      // The same guide, opened again from Settings.
      GoRoute(path: '/setup', builder: (_, _) => const OnboardingScreen()),
      ShellRoute(
        navigatorKey: _shellKey,
        builder: (context, state, child) => AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(path: '/', pageBuilder: (_, s) => NoTransitionPage(key: s.pageKey, child: const HomePane())),
          GoRoute(
            path: '/history',
            pageBuilder: (_, s) => NoTransitionPage(key: s.pageKey, child: const HistoryRoutePage()),
          ),
          // Category pages are siblings of the list, not stacked on it: one
          // settings page at a time, Back returns to the list.
          GoRoute(
            path: '/settings',
            pageBuilder: (_, s) => NoTransitionPage(key: s.pageKey, child: const SettingsScreen()),
          ),
          // Deep link targets of the keyboard ("Download a model", the style edit button).
          GoRoute(
            path: '/settings/models',
            pageBuilder: (_, s) =>
                NoTransitionPage(key: s.pageKey, child: const SettingsScreen(category: SettingsCategory.engine)),
          ),
          GoRoute(
            path: '/settings/style',
            pageBuilder: (_, s) =>
                NoTransitionPage(key: s.pageKey, child: const SettingsScreen(category: SettingsCategory.writing)),
          ),
          GoRoute(
            path: '/settings/:category',
            pageBuilder: (_, s) => NoTransitionPage(
              key: s.pageKey,
              child: SettingsScreen(category: SettingsCategory.byId(s.pathParameters['category'])),
            ),
          ),
        ],
      ),
    ],
  );
}

/// Router tied to the onboarding flag in settings.
final routerProvider = Provider<GoRouter>((ref) {
  final onboarded = ValueNotifier<bool>(ref.read(settingsProvider).onboarded);
  ref.listen(settingsProvider.select((s) => s.onboarded), (_, v) => onboarded.value = v);
  final router = buildRouter(onboarded: onboarded);
  ref.onDispose(() {
    router.dispose();
    onboarded.dispose();
  });
  return router;
});
