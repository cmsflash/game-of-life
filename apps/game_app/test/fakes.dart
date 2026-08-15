import 'dart:async';

import 'package:game_of_life/features/auth/data/auth_models.dart';
import 'package:game_of_life/features/auth/data/auth_repository.dart';
import 'package:game_of_life/features/auth/data/profile_avatar.dart';
import 'package:game_of_life/features/notifications/data/turn_notification_repository.dart';
import 'package:game_of_life/features/notifications/domain/turn_notifications.dart';
import 'package:game_of_life/features/notifications/platform/turn_notification_gateway.dart';
import 'package:game_of_life/features/online/data/online_models.dart';
import 'package:game_of_life/features/online/data/online_repository.dart';
import 'package:game_of_life/features/social/data/social_models.dart';
import 'package:game_of_life/features/social/data/social_repository.dart';
import 'package:game_of_life/features/stats/data/player_stats.dart';
import 'package:game_of_life/features/stats/data/player_stats_repository.dart';

class FakeAuthRepository implements AuthRepository {
  AppUser? current;
  Object? error;
  var loginCalls = 0;
  var uploadAvatarCalls = 0;
  var removeAvatarCalls = 0;
  Completer<AvatarDocument>? avatarGate;
  AvatarDocument avatarResult = const AvatarDocument(
    url: 'https://api.example.test/v1/players/user-1/avatar?v=1',
    version: 1,
  );
  Object? avatarError;

  @override
  Future<AppUser?> restore() async => current;

  @override
  Future<AppUser> login({
    required String username,
    required String password,
  }) async {
    loginCalls++;
    if (error != null) throw error!;
    return current = AppUser(
      id: 'user-1',
      username: username,
      displayName: username,
    );
  }

  @override
  Future<RegistrationResult> register({
    required String username,
    required String email,
    required String password,
    required String displayName,
  }) async =>
      RegistrationResult(username: username, confirmationRequired: true);

  @override
  Future<void> beginGoogleSignIn() async {}

  @override
  Future<AppUser> exchangeGoogleCode(String code) async =>
      current = const AppUser(
        id: 'google-1',
        username: 'google_player',
        displayName: 'Google Player',
      );

  @override
  Future<void> confirm({
    required String username,
    required String code,
  }) async {}

  @override
  Future<String?> forgotPassword(String username) async => null;

  @override
  Future<String?> resendConfirmation(String username) async => null;

  @override
  Future<void> logout() async => current = null;

  @override
  Future<void> deleteAccount() async {
    if (error != null) throw error!;
    current = null;
  }

  @override
  Future<void> resetPassword({
    required String username,
    required String code,
    required String newPassword,
  }) async {}

  @override
  Future<AvatarDocument> uploadAvatar(ProfileAvatarUpload upload) async {
    uploadAvatarCalls++;
    if (avatarError != null) throw avatarError!;
    return avatarGate == null ? avatarResult : avatarGate!.future;
  }

  @override
  Future<AvatarDocument> removeAvatar() async {
    removeAvatarCalls++;
    if (avatarError != null) throw avatarError!;
    return avatarGate == null
        ? AvatarDocument(url: null, version: avatarResult.version + 1)
        : avatarGate!.future;
  }

  @override
  Future<void> cacheUser(AppUser user) async {
    if (current?.id == user.id) current = user;
  }
}

class FakeProfileAvatarPicker implements ProfileAvatarPicker {
  ProfileAvatarUpload? result;
  Object? error;
  Completer<ProfileAvatarUpload?>? gate;
  var calls = 0;

  @override
  Future<ProfileAvatarUpload?> pick() async {
    calls++;
    if (error != null) throw error!;
    return gate == null ? result : gate!.future;
  }
}

class FakeTurnNotificationRepository implements TurnNotificationRepository {
  TurnNotificationConfiguration configurationValue =
      const TurnNotificationConfiguration(
        providers: {'webPush', 'firebase'},
        webPushVapidPublicKey: 'public-vapid-key',
      );
  final subscriptions = <TurnNotificationSubscription>[];
  final upserts = <TurnNotificationEndpoint>[];
  final deletedInstallationIds = <String>[];
  Completer<void>? listSubscriptionsGate;
  Completer<void>? upsertGate;
  var listSubscriptionsCalls = 0;
  var upsertCalls = 0;
  Object? error;
  Object? upsertError;

  @override
  Future<TurnNotificationConfiguration> configuration() async {
    if (error != null) throw error!;
    return configurationValue;
  }

  @override
  Future<List<TurnNotificationSubscription>> listSubscriptions() async {
    listSubscriptionsCalls++;
    await listSubscriptionsGate?.future;
    if (error != null) throw error!;
    return List.of(subscriptions);
  }

  @override
  Future<TurnNotificationSubscription> upsertSubscription(
    String installationId,
    TurnNotificationEndpoint endpoint, {
    String? locale,
    String? timeZone,
  }) async {
    upsertCalls++;
    await upsertGate?.future;
    if (upsertError != null) throw upsertError!;
    if (error != null) throw error!;
    upserts.add(endpoint);
    subscriptions.removeWhere(
      (subscription) => subscription.installationId == installationId,
    );
    final subscription = TurnNotificationSubscription(
      installationId: installationId,
      platform: endpoint.platform,
      provider: endpoint.provider,
      locale: locale,
      timeZone: timeZone,
    );
    subscriptions.add(subscription);
    return subscription;
  }

  @override
  Future<void> deleteSubscription(String installationId) async {
    deletedInstallationIds.add(installationId);
    if (error != null) throw error!;
    subscriptions.removeWhere(
      (subscription) => subscription.installationId == installationId,
    );
  }
}

class FakeTurnNotificationGateway implements TurnNotificationGateway {
  TurnNotificationCapability capabilityValue =
      const TurnNotificationCapability.notConfigured();
  TurnNotificationCapability? capabilityAfterRequest;
  TurnNotificationEndpoint? endpoint;
  TurnNotificationEndpoint? requestedEndpoint;
  var initializeCalls = 0;
  var requestCalls = 0;
  var deactivateCalls = 0;

  final endpointController =
      StreamController<TurnNotificationEndpoint>.broadcast();
  final foregroundController =
      StreamController<TurnNotificationMessage>.broadcast();
  final openedController =
      StreamController<TurnNotificationMessage>.broadcast();

  @override
  Future<TurnNotificationCapability> initialize(
    TurnNotificationConfiguration configuration,
  ) async {
    initializeCalls++;
    return capabilityValue;
  }

  @override
  Future<TurnNotificationCapability> capability() async => capabilityValue;

  @override
  Future<TurnNotificationEndpoint?> currentEndpoint() async => endpoint;

  @override
  Future<TurnNotificationEndpoint?> requestEndpoint() async {
    requestCalls++;
    capabilityValue = capabilityAfterRequest ?? capabilityValue;
    return requestedEndpoint ?? endpoint;
  }

  @override
  Future<void> deactivate() async {
    deactivateCalls++;
    endpoint = null;
  }

  @override
  Stream<TurnNotificationEndpoint> get endpointChanges =>
      endpointController.stream;

  @override
  Stream<TurnNotificationMessage> get foregroundMessages =>
      foregroundController.stream;

  @override
  Stream<TurnNotificationMessage> get openedMessages => openedController.stream;

  @override
  Future<void> dispose() async {
    await endpointController.close();
    await foregroundController.close();
    await openedController.close();
  }
}

class FakeOnlineRepository implements OnlineRepository {
  FakeOnlineRepository({this.matches = const [], this.match});

  List<OnlineMatchSummary> matches;
  OnlineMatch? match;
  final ticketPoll = Completer<MatchmakingTicket>();
  final lobbyPoll = Completer<PrivateLobby>();
  var listCalls = 0;
  var quickMatchCalls = 0;
  var cancelTicketCalls = 0;
  var createPrivateCalls = 0;
  var closeLobbyCalls = 0;

  @override
  Future<MatchPage> listMatches() async {
    listCalls++;
    return MatchPage(matches, null);
  }

  @override
  Future<MatchmakingTicket> startQuickMatch() async {
    quickMatchCalls++;
    return const MatchmakingTicket(
      id: 'ticket-test-000001',
      status: 'waiting',
      pollAfter: Duration.zero,
    );
  }

  @override
  Future<MatchmakingTicket> getTicket(String id) => ticketPoll.future;

  @override
  Future<void> cancelTicket(String id) async {
    cancelTicketCalls++;
  }

  @override
  Future<PrivateLobby> createPrivateLobby() async {
    createPrivateCalls++;
    return const PrivateLobby(
      id: 'lobby-test-000001',
      status: 'waiting',
      pollAfter: Duration.zero,
      joinCode: 'LIFE42',
    );
  }

  @override
  Future<PrivateLobby> getLobby(String id) => lobbyPoll.future;

  @override
  Future<PrivateLobby> joinLobby(String code) async => const PrivateLobby(
    id: 'match-joined',
    status: 'matched',
    pollAfter: Duration.zero,
    matchId: 'match-joined',
  );

  @override
  Future<void> closeLobby(String id) async {
    closeLobbyCalls++;
  }

  @override
  Future<OnlineMatch?> getMatch(String id, {String? etag}) async => match;

  @override
  Future<OnlineMatch> submitMove(
    String id, {
    required int revision,
    required int row,
    required int column,
  }) => throw UnimplementedError();

  @override
  Future<OnlineMatch> resign(String id, int revision) =>
      throw UnimplementedError();
}

class FakeSocialRepository implements SocialRepository {
  FakeSocialRepository({
    this.overview = const SocialOverview(),
    this.searchResults = const [],
  });

  SocialOverview overview;
  List<PublicPlayer> searchResults;
  Object? overviewError;
  Object? searchError;
  Object? mutationError;
  String acceptedMatchId = 'social-match-1';
  var overviewCalls = 0;
  var searchCalls = 0;
  final sentFriendRequests = <String>[];
  final acceptedFriendRequests = <String>[];
  final removedFriendRequests = <String>[];
  final removedFriends = <String>[];
  final createdChallenges = <String>[];
  final acceptedChallenges = <String>[];
  final removedChallenges = <String>[];

  @override
  Future<SocialOverview> getOverview() async {
    overviewCalls++;
    if (overviewError != null) throw overviewError!;
    return overview;
  }

  @override
  Future<List<PublicPlayer>> searchPlayers(String query) async {
    searchCalls++;
    if (searchError != null) throw searchError!;
    return searchResults;
  }

  void _throwMutationError() {
    if (mutationError != null) throw mutationError!;
  }

  @override
  Future<void> sendFriendRequest(String playerId) async {
    _throwMutationError();
    sentFriendRequests.add(playerId);
  }

  @override
  Future<void> acceptFriendRequest(String requestId) async {
    _throwMutationError();
    acceptedFriendRequests.add(requestId);
  }

  @override
  Future<void> removeFriendRequest(String requestId) async {
    _throwMutationError();
    removedFriendRequests.add(requestId);
  }

  @override
  Future<void> unfriend(String playerId) async {
    _throwMutationError();
    removedFriends.add(playerId);
  }

  @override
  Future<void> createChallenge(String opponentId) async {
    _throwMutationError();
    createdChallenges.add(opponentId);
  }

  @override
  Future<String> acceptChallenge(String challengeId) async {
    _throwMutationError();
    acceptedChallenges.add(challengeId);
    return acceptedMatchId;
  }

  @override
  Future<void> removeChallenge(String challengeId) async {
    _throwMutationError();
    removedChallenges.add(challengeId);
  }
}

class FakePlayerStatsRepository implements PlayerStatsRepository {
  FakePlayerStatsRepository({
    this.stats = const PlayerStats(
      elo: 1200,
      victories: 0,
      totalGames: 0,
      kills: 0,
      losses: 0,
      draws: 0,
    ),
  });

  PlayerStats stats;
  Object? error;
  var calls = 0;

  @override
  Future<PlayerStats> getMyStats() async {
    calls++;
    if (error != null) throw error!;
    return stats;
  }
}
