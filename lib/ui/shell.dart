// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'screens/history_screen.dart';
import 'screens/record_screen.dart';
import 'theme/app_theme.dart';

/// Width of the history pane beside the recorder on desktop.
const double kHistoryPaneWidth = 400;

/// Focus target for Ctrl+H on desktop.
final FocusNode historySearchFocus = FocusNode(debugLabel: 'History search');

enum _Dest { record, history, settings }

_Dest _destOf(String location) {
  if (location.startsWith('/settings')) return _Dest.settings;
  if (location.startsWith('/history')) return _Dest.history;
  return _Dest.record;
}

String _pathOf(_Dest d) => switch (d) {
  _Dest.record => '/',
  _Dest.history => '/history',
  _Dest.settings => '/settings',
};

({String label, IconData icon, IconData selected}) _meta(_Dest d) =>
    switch (d) {
      _Dest.record => (
        label: 'Record',
        icon: Icons.mic_none_rounded,
        selected: Icons.mic_rounded,
      ),
      _Dest.history => (
        label: 'History',
        icon: Icons.history_rounded,
        selected: Icons.history_rounded,
      ),
      _Dest.settings => (
        label: 'Settings',
        icon: Icons.settings_outlined,
        selected: Icons.settings_rounded,
      ),
    };

/// Phone: one screen at a time with a bottom bar. Desktop: no chrome at all,
/// recorder and history side by side, settings one shortcut away.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final twoPane = MediaQuery.sizeOf(context).width >= kTwoPaneWidth;

    final body = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
            context.go('/settings'),
        const SingleActivator(LogicalKeyboardKey.keyH, control: true): () {
          if (!twoPane) {
            context.go('/history');
            return;
          }
          if (_destOf(location) != _Dest.record) context.go('/');
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => historySearchFocus.requestFocus(),
          );
        },
      },
      child: child,
    );

    if (twoPane) return Scaffold(body: body);

    final current = _destOf(location);
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _Dest.values.indexOf(current),
        onDestinationSelected: (i) => context.go(_pathOf(_Dest.values[i])),
        destinations: [
          for (final d in _Dest.values)
            NavigationDestination(
              icon: Icon(_meta(d).icon),
              selectedIcon: Icon(_meta(d).selected),
              label: _meta(d).label,
            ),
        ],
      ),
    );
  }
}

/// Home: the recorder, with history alongside when there is room.
class HomePane extends StatelessWidget {
  const HomePane({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    if (MediaQuery.sizeOf(context).width < kTwoPaneWidth) {
      return const SafeArea(bottom: false, child: RecordScreen());
    }
    return Row(
      children: [
        Expanded(
          child: SafeArea(
            child: RecordScreen(
              trailing: IconButton(
                tooltip: 'Settings (Ctrl+,)',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => context.go('/settings'),
              ),
            ),
          ),
        ),
        SizedBox(
          width: kHistoryPaneWidth,
          child: ColoredBox(
            color: c.surfaceContainerLow,
            child: SafeArea(
              child: HistoryScreen(
                embedded: true,
                searchFocus: historySearchFocus,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The history route: full screen on a phone, otherwise the two-pane home.
class HistoryRoutePage extends StatelessWidget {
  const HistoryRoutePage({super.key});

  @override
  Widget build(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= kTwoPaneWidth
      ? const HomePane()
      : const HistoryScreen();
}
