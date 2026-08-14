import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/api_client.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/auth/data/session_store.dart';
import 'features/auth/presentation/auth_controller.dart';
import 'features/game/data/game_view_settings_store.dart';
import 'features/game/data/local_game_store.dart';
import 'features/game/domain/game_view_settings.dart';
import 'features/game/presentation/local_games_controller.dart';
import 'features/notifications/data/turn_notification_repository.dart';
import 'features/notifications/platform/turn_notification_gateway.dart';
import 'features/notifications/platform/turn_notification_gateway_factory.dart';
import 'features/notifications/presentation/turn_notification_controller.dart';
import 'features/online/data/online_repository.dart';
import 'features/online/presentation/lobby_controller.dart';
import 'features/social/data/social_repository.dart';
import 'features/social/presentation/social_controller.dart';
import 'features/stats/data/player_stats_repository.dart';
import 'features/stats/presentation/player_stats_controller.dart';

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
      beforeSessionEnd: () async {
        ref.read(socialControllerProvider.notifier).disconnectAccount();
        ref.read(playerStatsControllerProvider.notifier).disconnectAccount();
        await Future.wait([
          ref.read(lobbyControllerProvider.notifier).disconnectAccount(),
          ref
              .read(turnNotificationControllerProvider.notifier)
              .disconnectAccount(),
        ]);
      },
    );
    final expirationSubscription = ref
        .watch(apiClientProvider)
        .sessionExpired
        .listen((_) {
          ref.read(lobbyControllerProvider.notifier).sessionEnded();
          ref.read(socialControllerProvider.notifier).disconnectAccount();
          ref.read(playerStatsControllerProvider.notifier).disconnectAccount();
          controller.sessionExpired();
        });
    ref.onDispose(expirationSubscription.cancel);
    scheduleMicrotask(controller.restore);
    return controller;
  },
);

final onlineRepositoryProvider = Provider<OnlineRepository>(
  (ref) => ApiOnlineRepository(ref.watch(apiClientProvider)),
);

final lobbyControllerProvider =
    StateNotifierProvider<LobbyController, LobbyState>(
      (ref) => LobbyController(ref.watch(onlineRepositoryProvider)),
    );

final socialRepositoryProvider = Provider<SocialRepository>(
  (ref) => ApiSocialRepository(ref.watch(apiClientProvider)),
);

final socialControllerProvider =
    StateNotifierProvider<SocialController, SocialState>(
      (ref) => SocialController(ref.watch(socialRepositoryProvider)),
    );

final playerStatsRepositoryProvider = Provider<PlayerStatsRepository>(
  (ref) => ApiPlayerStatsRepository(ref.watch(apiClientProvider)),
);

final playerStatsControllerProvider =
    StateNotifierProvider<PlayerStatsController, PlayerStatsState>(
      (ref) => PlayerStatsController(ref.watch(playerStatsRepositoryProvider)),
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

final localGameStoreProvider = Provider<LocalGameStore>(
  (ref) => SecureLocalGameStore(),
);

final localGamesProvider =
    StateNotifierProvider<LocalGamesController, LocalGamesState>((ref) {
      final controller = LocalGamesController(
        ref.watch(localGameStoreProvider),
      );
      scheduleMicrotask(controller.load);
      return controller;
    });

final gameViewSettingsStoreProvider = Provider<GameViewSettingsStore>(
  (ref) => SecureGameViewSettingsStore(),
);

final gameViewSettingsProvider =
    StateNotifierProvider<GameViewSettingsController, GameViewSettings>(
      (ref) =>
          GameViewSettingsController(ref.watch(gameViewSettingsStoreProvider)),
    );
