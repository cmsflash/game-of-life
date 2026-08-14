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

  test('failed cancellation keeps the ticket visible for retry', () async {
    final repository = DelayedPollingRepository(
      cancelError: const ApiException(
        statusCode: 503,
        code: 'temporarilyUnavailable',
        message: 'Try again.',
      ),
    );
    final controller = LobbyController(repository);

    final search = controller.startQuickMatch(
      intent: MatchmakingIntent.publicRoom,
    );
    await repository.pollStarted.future;
    await controller.cancelQuickMatch();

    expect(controller.state.ticket?.id, 'ticket-alice-000001');
    expect(controller.state.searching, isTrue);
    expect(controller.state.matchmakingIntent, MatchmakingIntent.publicRoom);
    expect(controller.state.error, 'Try again.');
    repository.pollResult.complete(
      const MatchmakingTicket(
        id: 'ticket-alice-000001',
        status: 'cancelled',
        pollAfter: Duration.zero,
      ),
    );
    await search;
    controller.dispose();
  });

  test('failed private-room closure keeps the code visible', () async {
    final repository = DelayedRoomRepository(
      closeError: const ApiException(
        statusCode: 503,
        code: 'temporarilyUnavailable',
        message: 'Try again.',
      ),
    );
    final controller = LobbyController(repository);

    final hosting = controller.createPrivateLobby();
    await repository.pollStarted.future;
    await controller.closePrivateLobby();

    expect(controller.state.privateLobby?.joinCode, 'LIFE42');
    expect(controller.state.hosting, isTrue);
    expect(controller.state.error, 'Try again.');
    repository.pollResult.complete(repository.waitingLobby);
    await hosting;
    controller.dispose();
  });

  test(
    'private-room close race opens the match that already started',
    () async {
      final repository = DelayedRoomRepository(
        closeError: const ApiException(
          statusCode: 409,
          code: 'matchUnavailable',
          message: 'Only a waiting match may be cancelled.',
        ),
        refreshedLobby: const PrivateLobby(
          id: 'room-1',
          status: 'matched',
          pollAfter: Duration.zero,
          matchId: 'match-1',
        ),
      );
      final controller = LobbyController(repository);

      final hosting = controller.createPrivateLobby();
      await repository.pollStarted.future;
      await controller.closePrivateLobby();

      expect(controller.state.matchedId, 'match-1');
      expect(controller.state.privateLobby, isNull);
      repository.pollResult.complete(repository.waitingLobby);
      await hosting;
      controller.dispose();
    },
  );

  test('closing a recovered room does not stop an unrelated search', () async {
    final repository = DelayedPollingRepository(
      matches: const [
        OnlineMatchSummary(
          id: 'recovered-room',
          status: 'waiting',
          updatedAt: null,
          opponentName: 'Waiting for player',
          joinCode: 'LIFE42',
        ),
      ],
    );
    final controller = LobbyController(repository);

    final search = controller.startQuickMatch();
    await repository.pollStarted.future;
    await controller.loadMatches();
    await controller.closeWaitingRoom('recovered-room');
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
    expect(repository.closeLobbyCalls, 1);
    controller.dispose();
  });
}

class DelayedPollingRepository implements OnlineRepository {
  DelayedPollingRepository({this.cancelError, this.matches = const []});

  final ApiException? cancelError;
  final List<OnlineMatchSummary> matches;
  final pollStarted = Completer<void>();
  final pollResult = Completer<MatchmakingTicket>();
  var closeLobbyCalls = 0;

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
  Future<void> closeLobby(String id) async {
    closeLobbyCalls++;
  }

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
  Future<MatchPage> listMatches() async => MatchPage(matches, null);

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

class DelayedRoomRepository implements OnlineRepository {
  DelayedRoomRepository({this.closeError, this.refreshedLobby});

  final ApiException? closeError;
  final PrivateLobby? refreshedLobby;
  final pollStarted = Completer<void>();
  final pollResult = Completer<PrivateLobby>();
  var getLobbyCalls = 0;

  final waitingLobby = const PrivateLobby(
    id: 'room-1',
    status: 'waiting',
    pollAfter: Duration.zero,
    joinCode: 'LIFE42',
  );

  @override
  Future<PrivateLobby> createPrivateLobby() async => waitingLobby;

  @override
  Future<PrivateLobby> getLobby(String id) {
    getLobbyCalls++;
    if (getLobbyCalls == 1) {
      if (!pollStarted.isCompleted) pollStarted.complete();
      return pollResult.future;
    }
    return Future.value(refreshedLobby ?? waitingLobby);
  }

  @override
  Future<void> closeLobby(String id) async {
    final error = closeError;
    if (error != null) throw error;
  }

  @override
  Future<void> cancelTicket(String id) => throw UnimplementedError();

  @override
  Future<MatchmakingTicket> getTicket(String id) => throw UnimplementedError();

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
  Future<MatchmakingTicket> startQuickMatch() => throw UnimplementedError();

  @override
  Future<OnlineMatch> submitMove(
    String id, {
    required int revision,
    required int row,
    required int column,
  }) => throw UnimplementedError();
}
