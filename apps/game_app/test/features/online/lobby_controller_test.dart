import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/core/api_client.dart';
import 'package:game_of_life/features/online/data/online_models.dart';
import 'package:game_of_life/features/online/data/online_repository.dart';
import 'package:game_of_life/features/online/presentation/lobby_controller.dart';

void main() {
  test('a completed poll cannot restore a ticket after cancellation', () async {
    final repository = DelayedPollingRepository();
    final controller = LobbyController(repository);

    final search = controller.startQuickMatch();
    await repository.pollStarted.future;
    await controller.cancelQuickMatch();
    repository.pollResult.complete(
      const MatchmakingTicket(
        id: 'ticket-alice-000001',
        status: 'matched',
        pollAfter: Duration.zero,
        matchId: 'match-1',
      ),
    );
    await search;

    expect(controller.state.ticket, isNull);
    expect(controller.state.matchedId, isNull);
    controller.dispose();
  });

  test('cancellation opens the match when the match won the race', () async {
    final repository = DelayedPollingRepository(
      cancelError: const ApiException(
        statusCode: 409,
        code: 'matchAlreadyFound',
        message: 'A match was found.',
        details: {'matchId': 'match-1'},
      ),
    );
    final controller = LobbyController(repository);

    final search = controller.startQuickMatch();
    await repository.pollStarted.future;
    await controller.cancelQuickMatch();
    repository.pollResult.complete(
      const MatchmakingTicket(
        id: 'ticket-alice-000001',
        status: 'matched',
        pollAfter: Duration.zero,
        matchId: 'match-1',
      ),
    );
    await search;

    expect(controller.state.matchedId, 'match-1');
    controller.dispose();
  });
}

class DelayedPollingRepository implements OnlineRepository {
  DelayedPollingRepository({this.cancelError});

  final ApiException? cancelError;
  final pollStarted = Completer<void>();
  final pollResult = Completer<MatchmakingTicket>();

  @override
  Future<MatchmakingTicket> startQuickMatch() async => const MatchmakingTicket(
    id: 'ticket-alice-000001',
    status: 'waiting',
    pollAfter: Duration.zero,
  );

  @override
  Future<MatchmakingTicket> getTicket(String id) {
    if (!pollStarted.isCompleted) pollStarted.complete();
    return pollResult.future;
  }

  @override
  Future<void> cancelTicket(String id) async {
    final error = cancelError;
    if (error != null) throw error;
  }

  @override
  Future<void> closeLobby(String id) => throw UnimplementedError();

  @override
  Future<PrivateLobby> createPrivateLobby() => throw UnimplementedError();

  @override
  Future<PrivateLobby> getLobby(String id) => throw UnimplementedError();

  @override
  Future<OnlineMatch?> getMatch(String id, {String? etag}) =>
      throw UnimplementedError();

  @override
  Future<PrivateLobby> joinLobby(String code) => throw UnimplementedError();

  @override
  Future<MatchPage> listMatches() => throw UnimplementedError();

  @override
  Future<OnlineMatch> resign(String id, int revision) =>
      throw UnimplementedError();

  @override
  Future<OnlineMatch> submitMove(
    String id, {
    required int revision,
    required int row,
    required int column,
  }) => throw UnimplementedError();
}
