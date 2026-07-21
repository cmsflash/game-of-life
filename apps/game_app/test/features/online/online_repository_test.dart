import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:game_of_life/core/api_client.dart';
import 'package:game_of_life/features/auth/data/session_store.dart';
import 'package:game_of_life/features/online/data/online_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('quick matchmaking polls and cancels its exact ticket', () async {
    final requests = <http.Request>[];
    final store = MemorySessionStore()
      ..session = const StoredSession(
        accessToken: 'access',
        refreshToken: null,
      );
    late String ticketId;
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        ticketId = body['ticketId'] as String;
        return http.Response(
          jsonEncode({
            'ticketId': ticketId,
            'status': 'waiting',
            'matchId': null,
          }),
          200,
        );
      }
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'ticketId': request.url.queryParameters['ticketId'],
            'status': 'waiting',
            'matchId': null,
          }),
          200,
        );
      }
      return http.Response(jsonEncode({'message': 'cancelled'}), 200);
    });
    final repository = ApiOnlineRepository(
      ApiClient(
        sessionStore: store,
        httpClient: client,
        baseUrl: 'https://api.example.test',
      ),
    );

    final ticket = await repository.startQuickMatch();
    await repository.getTicket(ticket.id);
    await repository.cancelTicket(ticket.id);

    expect(ticket.id, ticketId);
    expect(ticket.id, isNotEmpty);
    expect(requests[1].url.queryParameters['ticketId'], ticket.id);
    expect(requests[2].url.queryParameters['ticketId'], ticket.id);
  });

  test(
    'private cancellation and resignation match the v1 wire contract',
    () async {
      final requests = <http.Request>[];
      final store = MemorySessionStore()
        ..session = const StoredSession(
          accessToken: 'access',
          refreshToken: 'refresh',
        );
      final client = MockClient((request) async {
        requests.add(request);
        if (request.method == 'DELETE') {
          return http.Response(jsonEncode({'message': 'cancelled'}), 200);
        }
        return http.Response(jsonEncode(_matchDocument()), 200);
      });
      final repository = ApiOnlineRepository(
        ApiClient(
          sessionStore: store,
          httpClient: client,
          baseUrl: 'https://api.example.test',
        ),
      );

      await repository.closeLobby('match-1');
      await repository.resign('match-1', 7);

      expect(requests.first.method, 'DELETE');
      expect(requests.first.url.path, '/v1/matches/match-1');
      final body = jsonDecode(requests.last.body) as Map<String, dynamic>;
      expect(body['expectedRevision'], 7);
      expect(body['idempotencyKey'], isA<String>());
      expect((body['idempotencyKey'] as String).length, greaterThan(8));
    },
  );
}

Map<String, dynamic> _matchDocument() {
  final state = const engine.GameEngine().initialState().toJson();
  return {
    'id': 'match-1',
    'version': 3,
    'joinCode': 'ABC234',
    'rules': engine.GameRules.standard().toJson(),
    'state': state,
    'blackPlayer': {'id': 'a', 'displayName': 'Alice'},
    'whitePlayer': {'id': 'b', 'displayName': 'Bob'},
    'yourColor': 'black',
    'status': 'active',
    'result': null,
    'createdAt': '2026-01-01T00:00:00Z',
    'updatedAt': '2026-01-01T00:00:00Z',
  };
}
