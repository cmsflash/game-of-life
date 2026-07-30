import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/auth/presentation/auth_controller.dart';
import 'features/auth/presentation/auth_screens.dart';
import 'features/auth/presentation/profile_screen.dart';
import 'features/game/presentation/local_game_screen.dart';
import 'features/game/presentation/local_setup_screen.dart';
import 'features/home/home_screen.dart';
import 'features/legal/legal_screens.dart';
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
        pageBuilder: (context, state, child) =>
            _page(state, AppShell(child: child)),
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (context, state) => _page(state, const HomeScreen()),
          ),
          GoRoute(
            path: '/local/setup',
            pageBuilder: (context, state) =>
                _page(state, const LocalSetupScreen()),
          ),
          GoRoute(
            path: '/online',
            pageBuilder: (context, state) => _page(state, const LobbyScreen()),
          ),
          GoRoute(
            path: '/profile',
            pageBuilder: (context, state) =>
                _page(state, const ProfileScreen()),
          ),
          GoRoute(
            path: '/about',
            pageBuilder: (context, state) =>
                _page(state, const LegalScreen(document: LegalDocument.about)),
          ),
          GoRoute(
            path: '/privacy',
            pageBuilder: (context, state) => _page(
              state,
              const LegalScreen(document: LegalDocument.privacy),
            ),
          ),
          GoRoute(
            path: '/terms',
            pageBuilder: (context, state) =>
                _page(state, const LegalScreen(document: LegalDocument.terms)),
          ),
          GoRoute(
            path: '/account-deletion',
            pageBuilder: (context, state) => _page(
              state,
              const LegalScreen(document: LegalDocument.accountDeletion),
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/local/game',
        pageBuilder: (context, state) => _page(state, const LocalGameScreen()),
      ),
      GoRoute(
        path: '/online/match/:id',
        pageBuilder: (context, state) => _page(
          state,
          OnlineMatchScreen(matchId: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) => _page(
          state,
          LoginScreen(returnTo: state.uri.queryParameters['returnTo']),
        ),
      ),
      GoRoute(
        path: '/register',
        pageBuilder: (context, state) => _page(state, const RegisterScreen()),
      ),
      GoRoute(
        path: '/confirm',
        pageBuilder: (context, state) => _page(
          state,
          ConfirmAccountScreen(
            initialUsername: state.uri.queryParameters['username'],
            initialCode: state.uri.queryParameters['code'],
          ),
        ),
      ),
      GoRoute(
        path: '/forgot-password',
        pageBuilder: (context, state) =>
            _page(state, const ForgotPasswordScreen()),
      ),
      GoRoute(
        path: '/reset-password',
        pageBuilder: (context, state) => _page(
          state,
          ResetPasswordScreen(
            initialUsername: state.uri.queryParameters['username'],
            initialCode: state.uri.queryParameters['code'],
          ),
        ),
      ),
      GoRoute(
        path: '/auth',
        pageBuilder: (context, state) => _page(
          state,
          GoogleCallbackScreen(code: state.uri.queryParameters['code']),
        ),
      ),
      GoRoute(
        path: '/auth/callback',
        pageBuilder: (context, state) => _page(
          state,
          GoogleCallbackScreen(code: state.uri.queryParameters['code']),
        ),
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

NoTransitionPage<void> _page(GoRouterState state, Widget child) =>
    NoTransitionPage<void>(key: state.pageKey, child: child);

class _RouterRefreshNotifier extends ChangeNotifier {
  void refresh() => notifyListeners();
}
