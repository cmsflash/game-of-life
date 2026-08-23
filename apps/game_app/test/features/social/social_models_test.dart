import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/features/social/data/social_models.dart';
import 'package:game_of_life/features/stats/data/player_stats.dart';

void main() {
  test('public player exposes username, display name, ID, and signed Elo', () {
    final player = PublicPlayer.fromJson({
      'id': 'player-1',
      'displayName': '  Fern  ',
      'rating': -37,
      'username': '  fern_player  ',
      'email': 'private@example.test',
      'avatarUrl': 'https://api.example.test/v1/players/player-1/avatar?v=7',
      'avatarVersion': 7,
    });

    expect(player.id, 'player-1');
    expect(player.displayName, 'Fern');
    expect(player.username, 'fern_player');
    expect(player.elo, -37);
    expect(player.avatarVersion, 7);
    expect(player.avatarUrl, endsWith('avatar?v=7'));
  });

  test('public player tolerates an absent or blank public username', () {
    final missing = PublicPlayer.fromJson({
      'id': 'google-1',
      'displayName': 'Google Player',
      'rating': 1200,
    });
    final blank = PublicPlayer.fromJson({
      'id': 'legacy-1',
      'displayName': 'Legacy Player',
      'username': '   ',
      'rating': 1200,
    });

    expect(missing.username, isNull);
    expect(blank.username, isNull);
  });

  test('public player rejects a missing authoritative rating', () {
    expect(
      () => PublicPlayer.fromJson({'id': 'player-1', 'displayName': 'Fern'}),
      throwsFormatException,
    );
  });

  test('challenge chooses the other player and uses server expiry', () {
    final json = {
      'id': 'challenge-1',
      'challenger': {'id': 'alice', 'displayName': 'Alice', 'rating': 1210},
      'opponent': {'id': 'bob', 'displayName': 'Bob', 'rating': 1190},
      'createdAt': '2026-08-14T00:00:00Z',
      'expiresAt': '2026-08-20T12:30:00Z',
    };

    final incoming = PlayerChallenge.fromJson(json, incoming: true);
    final outgoing = PlayerChallenge.fromJson(json, incoming: false);

    expect(incoming.player.displayName, 'Alice');
    expect(outgoing.player.displayName, 'Bob');
    expect(incoming.expiresAt, DateTime.utc(2026, 8, 20, 12, 30));
  });

  test('stats use every completed game in win-rate denominator', () {
    final stats = PlayerStats.fromJson({
      'rating': -8,
      'games': 10,
      'wins': 6,
      'losses': 3,
      'draws': 1,
      'kills': 42,
      'spawns': 64,
    });

    expect(stats.elo, -8);
    expect(stats.winRate, .6);
    expect(stats.totalGames, stats.victories + stats.losses + stats.draws);
    expect(stats.kills, 42);
    expect(stats.spawns, 64);
  });

  test('stats reject an inconsistent completed-game breakdown', () {
    expect(
      () => PlayerStats.fromJson({
        'rating': 1200,
        'games': 4,
        'wins': 2,
        'losses': 1,
        'draws': 0,
        'kills': 3,
        'spawns': 4,
      }),
      throwsFormatException,
    );
  });

  test('stats default spawns to zero for rolling backend compatibility', () {
    final stats = PlayerStats.fromJson({
      'rating': 1200,
      'games': 0,
      'wins': 0,
      'losses': 0,
      'draws': 0,
      'kills': 0,
    });

    expect(stats.spawns, 0);
  });
}
