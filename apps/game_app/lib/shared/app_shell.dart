import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/presentation/auth_controller.dart';
import '../providers.dart';
import 'life_logo.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  static const _destinations = [
    ('/', 'Home', Icons.home_outlined, Icons.home),
    ('/social', 'Social', Icons.people_outline, Icons.people),
    ('/settings', 'Settings', Icons.settings_outlined, Icons.settings),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;
    final location = GoRouterState.of(context).uri.path;
    final selected = _indexFor(location);
    final auth = ref.watch(authControllerProvider);

    final body = Scaffold(
      appBar: wide
          ? null
          : AppBar(
              title: const LifeLogo(),
              actions: [
                if (auth.status == AuthStatus.signedOut)
                  TextButton(
                    onPressed: () => context.go('/login'),
                    child: const Text('Sign in'),
                  ),
                const SizedBox(width: 8),
              ],
            ),
      body: child,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: selected,
              onDestinationSelected: (index) =>
                  context.go(_destinations[index].$1),
              destinations: [
                for (final destination in _destinations)
                  NavigationDestination(
                    icon: Icon(destination.$3),
                    selectedIcon: Icon(destination.$4),
                    label: destination.$2,
                  ),
              ],
            ),
    );
    if (!wide) return body;
    return Scaffold(
      body: Row(
        children: [
          SafeArea(
            right: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 18, 6, 18),
              child: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 26),
                    child: LifeLogo(compact: true),
                  ),
                  Expanded(
                    child: NavigationRail(
                      selectedIndex: selected,
                      onDestinationSelected: (index) =>
                          context.go(_destinations[index].$1),
                      destinations: [
                        for (final destination in _destinations)
                          NavigationRailDestination(
                            icon: Icon(destination.$3),
                            selectedIcon: Icon(destination.$4),
                            label: Text(destination.$2),
                          ),
                      ],
                    ),
                  ),
                  if (auth.status == AuthStatus.signedOut)
                    IconButton.filledTonal(
                      tooltip: 'Sign in',
                      onPressed: () => context.go('/login'),
                      icon: const Icon(Icons.login),
                    ),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ],
      ),
    );
  }

  int _indexFor(String location) {
    if (location.startsWith('/social')) return 1;
    if (location.startsWith('/settings') ||
        location.startsWith('/player') ||
        location.startsWith('/profile') ||
        location.startsWith('/about') ||
        location.startsWith('/privacy') ||
        location.startsWith('/terms') ||
        location.startsWith('/account-deletion')) {
      return 2;
    }
    return 0;
  }
}
