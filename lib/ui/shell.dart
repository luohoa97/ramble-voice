// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'screens/history_screen.dart';
import 'screens/record_screen.dart';

const double kMediumBreakpoint = 600;

/// Width at which record and history sit side by side.
const double kTwoPaneBreakpoint = 900;

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

({String label, IconData icon, IconData selected}) _meta(_Dest d) => switch (d) {
      _Dest.record => (label: 'Record', icon: Icons.mic_none_rounded, selected: Icons.mic_rounded),
      _Dest.history => (label: 'History', icon: Icons.history_rounded, selected: Icons.history_rounded),
      _Dest.settings => (label: 'Settings', icon: Icons.settings_outlined, selected: Icons.settings_rounded),
    };

/// Adaptive scaffold: NavigationBar when compact, NavigationRail otherwise.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final twoPane = width >= kTwoPaneBreakpoint;
    final dests = [for (final d in _Dest.values) if (!(twoPane && d == _Dest.history)) d];
    var current = _destOf(location);
    if (twoPane && current == _Dest.history) current = _Dest.record;
    final index = dests.indexOf(current);

    void go(int i) => context.go(_pathOf(dests[i]));

    final body = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () => context.go('/settings'),
        const SingleActivator(LogicalKeyboardKey.keyH, control: true): () => context.go('/history'),
      },
      child: child,
    );

    if (width < kMediumBreakpoint) {
      return Scaffold(
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: go,
          destinations: [
            for (final d in dests)
              NavigationDestination(
                icon: Icon(_meta(d).icon),
                selectedIcon: Icon(_meta(d).selected),
                label: _meta(d).label,
              ),
          ],
        ),
      );
    }
    return Scaffold(
      body: Row(
        children: [
          SafeArea(
            child: NavigationRail(
              selectedIndex: index,
              onDestinationSelected: go,
              destinations: [
                for (final d in dests)
                  NavigationRailDestination(
                    icon: Icon(_meta(d).icon),
                    selectedIcon: Icon(_meta(d).selected),
                    label: Text(_meta(d).label),
                  ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// Home: record, plus history alongside when there is room.
class HomePane extends StatelessWidget {
  const HomePane({super.key});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final record = const RecordScreen();
    if (width < kTwoPaneBreakpoint) {
      return Scaffold(
        appBar: AppBar(title: const Text('Ramble Voice')),
        body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 840), child: record)),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Ramble Voice')),
      body: Row(
        children: [
          const Expanded(flex: 5, child: RecordScreen()),
          VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outlineVariant),
          const Expanded(flex: 4, child: HistoryScreen(embedded: true)),
        ],
      ),
    );
  }
}

/// The history route: full screen when compact, otherwise the two-pane home.
class HistoryRoutePage extends StatelessWidget {
  const HistoryRoutePage({super.key});

  @override
  Widget build(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= kTwoPaneBreakpoint ? const HomePane() : const HistoryScreen();
}
