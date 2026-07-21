import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/api_client.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/auth/data/session_store.dart';
import 'features/auth/presentation/auth_controller.dart';
import 'features/game/domain/game_session.dart';
import 'features/online/data/online_repository.dart';

final sessionStoreProvider = Provider<SessionStore>(
  (ref) => SecureSessionStore(),
);

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(sessionStore: ref.watch(sessionStoreProvider));
  ref.onDispose(client.close);
  return client;
});

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => ApiAuthRepository(
    api: ref.watch(apiClientProvider),
    sessionStore: ref.watch(sessionStoreProvider),
    browserLauncher: SystemBrowserLauncher(),
  ),
);

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>(
  (ref) {
    final controller = AuthController(ref.watch(authRepositoryProvider));
    final expirationSubscription = ref
        .watch(apiClientProvider)
        .sessionExpired
        .listen((_) => controller.sessionExpired());
    ref.onDispose(expirationSubscription.cancel);
    scheduleMicrotask(controller.restore);
    return controller;
  },
);

final onlineRepositoryProvider = Provider<OnlineRepository>(
  (ref) => ApiOnlineRepository(ref.watch(apiClientProvider)),
);

final localGameProvider =
    StateNotifierProvider<LocalGameController, LocalGameSession?>(
      (ref) => LocalGameController(),
    );
