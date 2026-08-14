import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/api_client.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/auth/data/session_store.dart';
import 'features/auth/presentation/auth_controller.dart';
import 'features/game/data/game_view_settings_store.dart';
import 'features/game/domain/game_session.dart';
import 'features/game/domain/game_view_settings.dart';
import 'features/notifications/data/turn_notification_repository.dart';
import 'features/notifications/platform/turn_notification_gateway.dart';
import 'features/notifications/platform/turn_notification_gateway_factory.dart';
import 'features/notifications/presentation/turn_notification_controller.dart';
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
    final controller = AuthController(
      ref.watch(authRepositoryProvider),
      beforeSessionEnd: () => ref
          .read(turnNotificationControllerProvider.notifier)
          .disconnectAccount(),
    );
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

final turnNotificationRepositoryProvider = Provider<TurnNotificationRepository>(
  (ref) => ApiTurnNotificationRepository(ref.watch(apiClientProvider)),
);

final turnNotificationGatewayProvider = Provider<TurnNotificationGateway>(
  (ref) => createTurnNotificationGateway(),
);

final turnNotificationControllerProvider =
    StateNotifierProvider<TurnNotificationController, TurnNotificationState>(
      (ref) => TurnNotificationController(
        repository: ref.watch(turnNotificationRepositoryProvider),
        gateway: ref.watch(turnNotificationGatewayProvider),
        sessionStore: ref.watch(sessionStoreProvider),
      ),
    );

final localGameProvider =
    StateNotifierProvider<LocalGameController, LocalGameSession?>(
      (ref) => LocalGameController(),
    );

final gameViewSettingsStoreProvider = Provider<GameViewSettingsStore>(
  (ref) => SecureGameViewSettingsStore(),
);

final gameViewSettingsProvider =
    StateNotifierProvider<GameViewSettingsController, GameViewSettings>(
      (ref) =>
          GameViewSettingsController(ref.watch(gameViewSettingsStoreProvider)),
    );
