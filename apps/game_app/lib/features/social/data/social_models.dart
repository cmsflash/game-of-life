class PublicPlayer {
  const PublicPlayer({
    required this.id,
    required this.displayName,
    required this.elo,
  });

  final String id;
  final String displayName;
  final int elo;

  factory PublicPlayer.fromJson(Map<String, dynamic> json) {
    final id =
        json['playerId'] as String? ??
        json['userId'] as String? ??
        json['id'] as String?;
    final displayName = json['displayName'] as String?;
    final rating = json['rating'];
    if (id == null || id.isEmpty) {
      throw const FormatException('A public player must include an ID.');
    }
    if (displayName == null || displayName.trim().isEmpty) {
      throw const FormatException(
        'A public player must include a display name.',
      );
    }
    if (rating is! num) {
      throw const FormatException(
        'A public player must include a valid rating.',
      );
    }
    return PublicPlayer(
      id: id,
      displayName: displayName.trim(),
      elo: rating.round(),
    );
  }
}

class FriendRequest {
  const FriendRequest({required this.id, required this.player, this.createdAt});

  final String id;
  final PublicPlayer player;
  final DateTime? createdAt;

  factory FriendRequest.fromJson(Map<String, dynamic> json) {
    final playerJson = json['player'];
    if (playerJson is! Map<String, dynamic>) {
      throw const FormatException(
        'A friend request must include its public player.',
      );
    }
    final id = json['requestId'] as String? ?? json['id'] as String?;
    if (id == null || id.isEmpty) {
      throw const FormatException('A friend request must include an ID.');
    }
    return FriendRequest(
      id: id,
      player: PublicPlayer.fromJson(playerJson),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    );
  }
}

class PlayerChallenge {
  const PlayerChallenge({
    required this.id,
    required this.player,
    required this.status,
    required this.expiresAt,
    this.createdAt,
    this.matchId,
  });

  final String id;
  final PublicPlayer player;
  final String status;
  final DateTime expiresAt;
  final DateTime? createdAt;
  final String? matchId;

  factory PlayerChallenge.fromJson(
    Map<String, dynamic> json, {
    required bool incoming,
  }) {
    final playerJson = json[incoming ? 'challenger' : 'opponent'];
    if (playerJson is! Map<String, dynamic>) {
      throw const FormatException(
        'A challenge must include its other public player.',
      );
    }
    final id = json['challengeId'] as String? ?? json['id'] as String?;
    if (id == null || id.isEmpty) {
      throw const FormatException('A challenge must include an ID.');
    }
    final expiresAt = DateTime.tryParse(json['expiresAt'] as String? ?? '');
    if (expiresAt == null) {
      throw const FormatException(
        'A challenge must include its authoritative expiry.',
      );
    }
    return PlayerChallenge(
      id: id,
      player: PublicPlayer.fromJson(playerJson),
      status: json['status'] as String? ?? 'pending',
      expiresAt: expiresAt,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      matchId: json['matchId'] as String?,
    );
  }
}

class SocialOverview {
  const SocialOverview({
    this.version = 0,
    this.discoverable = false,
    this.friends = const [],
    this.incomingFriendRequests = const [],
    this.outgoingFriendRequests = const [],
    this.incomingChallenges = const [],
    this.outgoingChallenges = const [],
  });

  final int version;
  final bool discoverable;
  final List<PublicPlayer> friends;
  final List<FriendRequest> incomingFriendRequests;
  final List<FriendRequest> outgoingFriendRequests;
  final List<PlayerChallenge> incomingChallenges;
  final List<PlayerChallenge> outgoingChallenges;
}

class DiscoverabilityResult {
  const DiscoverabilityResult({
    required this.discoverable,
    required this.version,
  });

  final bool discoverable;
  final int version;

  factory DiscoverabilityResult.fromJson(Map<String, dynamic> json) {
    final discoverable = json['discoverable'];
    final version = json['version'];
    if (discoverable is! bool || version is! num) {
      throw const FormatException(
        'Discoverability must include its canonical state and version.',
      );
    }
    return DiscoverabilityResult(
      discoverable: discoverable,
      version: version.round(),
    );
  }
}
