import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/core/api_client.dart';
import 'package:game_of_life/features/auth/data/session_store.dart';
import 'package:game_of_life/features/social/data/social_repository.dart';
import 'package:game_of_life/features/stats/data/player_stats_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'loads one canonical Social snapshot and public-only search results',
    () async {
      final paths = <String>[];
      final api = ApiClient(
        sessionStore: MemorySessionStore(),
        baseUrl: 'https://api.example.test',
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path == '/v1/players/search') {
            expect(request.url.queryParameters, {'q': 'Fer'});
            return http.Response(
              jsonEncode({
                'items': [
                  {
                    'id': 'fern',
                    'displayName': 'Fern',
                    'rating': -4,
                    'username': 'not_public',
                    'email': 'not-public@example.test',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(jsonEncode(_socialJson), 200);
        }),
      );
      final repository = ApiSocialRepository(api);

      final overview = await repository.getOverview();
      final results = await repository.searchPlayers(' Fer ');

      expect(paths, ['/v1/social', '/v1/players/search']);
      expect(overview.version, 8);
      expect(overview.friends.single.displayName, 'Briar');
      expect(overview.incomingChallenges.single.player.displayName, 'Cedar');
      expect(overview.outgoingChallenges.single.player.displayName, 'Dahlia');
      expect(results.single.displayName, 'Fern');
      expect(results.single.elo, -4);
    },
  );

  test('uses the frozen mutation paths and challenge bodies', () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      sessionStore: MemorySessionStore(),
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/v1/social/discoverability') {
          return http.Response(
            jsonEncode({'discoverable': true, 'version': 9}),
            200,
          );
        }
        if (request.url.path.endsWith('/accept') &&
            request.url.path.startsWith('/v1/challenges/')) {
          return http.Response(jsonEncode({'matchId': 'match-7'}), 200);
        }
        return http.Response('', 204);
      }),
    );
    final repository = ApiSocialRepository(api);

    await repository.sendFriendRequest('player 1');
    await repository.acceptFriendRequest('request 1');
    await repository.removeFriendRequest('request 2');
    await repository.unfriend('player 2');
    await repository.createChallenge('player 3');
    expect(await repository.acceptChallenge('challenge 1'), 'match-7');
    await repository.removeChallenge('challenge 2');
    final discoverability = await repository.setDiscoverable(true);

    expect(requests.map((request) => '${request.method} ${request.url.path}'), [
      'POST /v1/friends/requests',
      'POST /v1/friends/requests/request%201/accept',
      'DELETE /v1/friends/requests/request%202',
      'DELETE /v1/friends/player%202',
      'POST /v1/challenges',
      'POST /v1/challenges/challenge%201/accept',
      'DELETE /v1/challenges/challenge%202',
      'PATCH /v1/social/discoverability',
    ]);
    expect(jsonDecode(requests[0].body), {'playerId': 'player 1'});
    expect(jsonDecode(requests[4].body), {'opponentId': 'player 3'});
    expect((jsonDecode(requests[4].body) as Map).containsKey('rules'), isFalse);
    expect(jsonDecode(requests[7].body), {'discoverable': true});
    expect(discoverability.discoverable, isTrue);
    expect(discoverability.version, 9);
  });

  test('stats repository parses the authoritative completed record', () async {
    final api = ApiClient(
      sessionStore: MemorySessionStore(),
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/v1/stats/me');
        return http.Response(
          jsonEncode({
            'rating': -18,
            'games': 7,
            'wins': 3,
            'losses': 2,
            'draws': 2,
            'kills': 91,
          }),
          200,
        );
      }),
    );

    final stats = await ApiPlayerStatsRepository(api).getMyStats();

    expect(stats.elo, -18);
    expect(stats.totalGames, 7);
    expect(stats.winRate, closeTo(3 / 7, .0001));
  });
}

final _socialJson = {
  'version': 8,
  'discoverable': false,
  'friends': [
    {'id': 'briar', 'displayName': 'Briar', 'rating': 1301},
  ],
  'incomingFriendRequests': [
    {
      'id': 'request-in',
      'player': {'id': 'cedar', 'displayName': 'Cedar', 'rating': 1210},
      'createdAt': '2026-08-14T00:00:00Z',
    },
  ],
  'outgoingFriendRequests': <Object>[],
  'incomingChallenges': [
    {
      'id': 'challenge-in',
      'challenger': {'id': 'cedar', 'displayName': 'Cedar', 'rating': 1210},
      'opponent': {'id': 'me', 'displayName': 'Me', 'rating': 1200},
      'createdAt': '2026-08-14T00:00:00Z',
      'expiresAt': '2026-08-21T00:00:00Z',
    },
  ],
  'outgoingChallenges': [
    {
      'id': 'challenge-out',
      'challenger': {'id': 'me', 'displayName': 'Me', 'rating': 1200},
      'opponent': {'id': 'dahlia', 'displayName': 'Dahlia', 'rating': 1180},
      'createdAt': '2026-08-14T00:00:00Z',
      'expiresAt': '2026-08-21T00:00:00Z',
    },
  ],
};
