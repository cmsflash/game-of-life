import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/auth/presentation/auth_controller.dart';
import 'features/auth/presentation/auth_screens.dart';
import 'features/auth/presentation/profile_screen.dart';
import 'features/game/presentation/local_game_screen.dart';
import 'features/game/presentation/local_setup_screen.dart';
import 'features/home/home_screen.dart';
import 'features/online/presentation/lobby_screen.dart';
import 'features/online/presentation/online_match_screen.dart';
import 'providers.dart';
import 'shared/app_shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefreshNotifier();
  ref.listen<AuthState>(authControllerProvider, (_, _) => refresh.refresh());
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      if (state.uri.scheme == 'com.cmsflash.gameoflife' &&
          state.uri.host == 'auth') {
        final query = state.uri.hasQuery ? '?${state.uri.query}' : '';
        return '/auth/callback$query';
      }
      final auth = ref.read(authControllerProvider);
      if (auth.status == AuthStatus.loading) return null;
      final path = state.uri.path;
      final isAuthPage = path == '/login' || path == '/register';
      final protected =
          path == '/online' ||
          path.startsWith('/online/') ||
          path == '/profile';
      final callback = path == '/auth/callback' || path == '/auth';
      if (protected && auth.status != AuthStatus.signedIn) {
        return '/login?returnTo=${Uri.encodeComponent(state.uri.toString())}';
      }
      if (isAuthPage && auth.status == AuthStatus.signedIn) {
        final returnTo = state.uri.queryParameters['returnTo'];
        return returnTo ?? '/online';
      }
      if (callback) return null;
      return null;
    },
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
          GoRoute(
            path: '/local/setup',
            builder: (context, state) => const LocalSetupScreen(),
          ),
          GoRoute(
            path: '/online',
            builder: (context, state) => const LobbyScreen(),
          ),
          GoRoute(
            path: '/profile',
            builder: (context, state) => const ProfileScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/local/game',
        builder: (context, state) => const LocalGameScreen(),
      ),
      GoRoute(
        path: '/online/match/:id',
        builder: (context, state) =>
            OnlineMatchScreen(matchId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) =>
            LoginScreen(returnTo: state.uri.queryParameters['returnTo']),
      ),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/confirm',
        builder: (context, state) => ConfirmAccountScreen(
          initialUsername: state.uri.queryParameters['username'],
          initialCode: state.uri.queryParameters['code'],
        ),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (context, state) => const ForgotPasswordScreen(),
      ),
      GoRoute(
        path: '/reset-password',
        builder: (context, state) => ResetPasswordScreen(
          initialUsername: state.uri.queryParameters['username'],
          initialCode: state.uri.queryParameters['code'],
        ),
      ),
      GoRoute(
        path: '/auth',
        builder: (context, state) =>
            GoogleCallbackScreen(code: state.uri.queryParameters['code']),
      ),
      GoRoute(
        path: '/auth/callback',
        builder: (context, state) =>
            GoogleCallbackScreen(code: state.uri.queryParameters['code']),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.explore_off_outlined, size: 56),
              const SizedBox(height: 16),
              Text(
                'That square does not exist.',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go('/'),
                child: const Text('Return home'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
});

class _RouterRefreshNotifier extends ChangeNotifier {
  void refresh() => notifyListeners();
}
