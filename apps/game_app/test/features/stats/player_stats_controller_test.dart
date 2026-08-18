import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/core/api_client.dart';
import 'package:game_of_life/features/stats/data/player_stats.dart';
import 'package:game_of_life/features/stats/data/player_stats_repository.dart';
import 'package:game_of_life/features/stats/presentation/player_stats_controller.dart';

void main() {
  test(
    'account switch ignores stats returned for the previous player',
    () async {
      final repository = ScriptedStatsRepository();
      final first = Completer<PlayerStats>();
      final second = Completer<PlayerStats>();
      repository.responses
        ..add(first.future)
        ..add(second.future);
      final controller = PlayerStatsController(repository)..connectAccount('a');

      final oldLoad = controller.load();
      controller.connectAccount('b');
      final newLoad = controller.load();
      second.complete(_stats(elo: 1400));
      await newLoad;
      first.complete(_stats(elo: 900));
      await oldLoad;

      expect(controller.state.stats?.elo, 1400);
      controller.dispose();
    },
  );

  test('refresh replaces an already-ready rated record', () async {
    final repository = ScriptedStatsRepository();
    repository.responses
      ..add(Future.value(_stats(elo: 1200)))
      ..add(Future.value(_stats(elo: 1216, wins: 1, games: 1)));
    final controller = PlayerStatsController(repository)..connectAccount('a');

    await controller.load();
    await controller.refresh();

    expect(controller.state.stats?.elo, 1216);
    expect(controller.state.stats?.victories, 1);
    expect(repository.calls, 2);
    controller.dispose();
  });

  test(
    'account-fenced refresh connects before loading live evolution stats',
    () async {
      final repository = ScriptedStatsRepository();
      repository.responses.add(
        Future.value(_stats(elo: 1200, kills: 7, spawns: 11)),
      );
      final controller = PlayerStatsController(repository);

      await controller.refreshForAccount('a');

      expect(controller.state.status, PlayerStatsStatus.ready);
      expect(controller.state.stats?.kills, 7);
      expect(controller.state.stats?.spawns, 11);
      expect(repository.calls, 1);
      controller.dispose();
    },
  );

  test(
    'failed refresh keeps the last record and exposes retry error',
    () async {
      final repository = ScriptedStatsRepository();
      repository.responses
        ..add(Future.value(_stats(elo: 1200)))
        ..add(
          Future.error(
            const ApiException(
              statusCode: 503,
              code: 'statsBackfillInProgress',
              message: 'Stats are catching up. Try again.',
            ),
          ),
        );
      final controller = PlayerStatsController(repository)..connectAccount('a');

      await controller.load();
      await controller.refresh();

      expect(controller.state.stats?.elo, 1200);
      expect(controller.state.status, PlayerStatsStatus.failed);
      expect(controller.state.error, 'Stats are catching up. Try again.');
      controller.dispose();
    },
  );

  test('disconnect clears metrics and ignores a late response', () async {
    final repository = ScriptedStatsRepository();
    final response = Completer<PlayerStats>();
    repository.responses.add(response.future);
    final controller = PlayerStatsController(repository)..connectAccount('a');

    final pending = controller.load();
    controller.disconnectAccount();
    response.complete(_stats(elo: 1300));
    await pending;

    expect(controller.state.status, PlayerStatsStatus.idle);
    expect(controller.state.stats, isNull);
    controller.dispose();
  });
}

PlayerStats _stats({
  required int elo,
  int wins = 0,
  int games = 0,
  int kills = 0,
  int spawns = 0,
}) => PlayerStats(
  elo: elo,
  victories: wins,
  totalGames: games,
  kills: kills,
  spawns: spawns,
  losses: games - wins,
  draws: 0,
);

class ScriptedStatsRepository implements PlayerStatsRepository {
  final responses = Queue<Future<PlayerStats>>();
  var calls = 0;

  @override
  Future<PlayerStats> getMyStats() {
    calls++;
    return responses.removeFirst();
  }
}
