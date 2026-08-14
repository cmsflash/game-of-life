import '../../../core/api_client.dart';
import 'social_models.dart';

abstract interface class SocialRepository {
  Future<List<PublicPlayer>> searchPlayers(String query);
  Future<SocialOverview> getOverview();
  Future<void> sendFriendRequest(String playerId);
  Future<void> acceptFriendRequest(String requestId);
  Future<void> removeFriendRequest(String requestId);
  Future<void> unfriend(String playerId);
  Future<void> createChallenge(String opponentId);
  Future<String> acceptChallenge(String challengeId);
  Future<void> removeChallenge(String challengeId);
  Future<DiscoverabilityResult> setDiscoverable(bool discoverable);
}

class ApiSocialRepository implements SocialRepository {
  const ApiSocialRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<PublicPlayer>> searchPlayers(String query) async {
    final response = await _api.get(
      '/v1/players/search',
      query: {'q': query.trim()},
    );
    return _players(response.data);
  }

  @override
  Future<SocialOverview> getOverview() async {
    final response = await _api.get('/v1/social');
    final social = _map(response.data);
    return SocialOverview(
      version: (social['version'] as num?)?.round() ?? 0,
      discoverable: social['discoverable'] as bool? ?? false,
      friends: _players(social['friends']),
      incomingFriendRequests: _friendRequests(social['incomingFriendRequests']),
      outgoingFriendRequests: _friendRequests(social['outgoingFriendRequests']),
      incomingChallenges: _challenges(
        social['incomingChallenges'],
        incoming: true,
      ),
      outgoingChallenges: _challenges(
        social['outgoingChallenges'],
        incoming: false,
      ),
    );
  }

  @override
  Future<void> sendFriendRequest(String playerId) async {
    await _api.post(
      '/v1/friends/requests',
      idempotent: true,
      body: {'playerId': playerId},
    );
  }

  @override
  Future<void> acceptFriendRequest(String requestId) async {
    await _api.post(
      '/v1/friends/requests/${Uri.encodeComponent(requestId)}/accept',
      idempotent: true,
    );
  }

  @override
  Future<void> removeFriendRequest(String requestId) async {
    await _api.delete('/v1/friends/requests/${Uri.encodeComponent(requestId)}');
  }

  @override
  Future<void> unfriend(String playerId) async {
    await _api.delete('/v1/friends/${Uri.encodeComponent(playerId)}');
  }

  @override
  Future<void> createChallenge(String opponentId) async {
    await _api.post(
      '/v1/challenges',
      idempotent: true,
      body: {'opponentId': opponentId},
    );
  }

  @override
  Future<String> acceptChallenge(String challengeId) async {
    final response = await _api.post(
      '/v1/challenges/${Uri.encodeComponent(challengeId)}/accept',
      idempotent: true,
    );
    final matchId = _map(response.data)['matchId'] as String?;
    if (matchId == null || matchId.isEmpty) {
      throw const FormatException(
        'An accepted challenge must include its match ID.',
      );
    }
    return matchId;
  }

  @override
  Future<void> removeChallenge(String challengeId) async {
    await _api.delete('/v1/challenges/${Uri.encodeComponent(challengeId)}');
  }

  @override
  Future<DiscoverabilityResult> setDiscoverable(bool discoverable) async {
    final response = await _api.patch(
      '/v1/social/discoverability',
      body: {'discoverable': discoverable},
    );
    return DiscoverabilityResult.fromJson(
      response.data as Map<String, dynamic>,
    );
  }
}

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : const {};

List<PublicPlayer> _players(Object? value) {
  final items = value is List ? value : _map(value)['items'];
  return [
    for (final item in items is List ? items : const <Object?>[])
      if (item is Map<String, dynamic>) PublicPlayer.fromJson(item),
  ];
}

List<FriendRequest> _friendRequests(Object? value) => [
  for (final item in value is List ? value : const <Object?>[])
    if (item is Map<String, dynamic>) FriendRequest.fromJson(item),
];

List<PlayerChallenge> _challenges(Object? value, {required bool incoming}) => [
  for (final item in value is List ? value : const <Object?>[])
    if (item is Map<String, dynamic>)
      PlayerChallenge.fromJson(item, incoming: incoming),
];
