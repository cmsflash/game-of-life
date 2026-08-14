import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:game_of_life/features/online/data/online_models.dart';
import 'package:game_of_life/features/online/data/online_repository.dart';
import 'package:game_of_life/features/online/presentation/online_match_screen.dart';
import 'package:game_of_life/features/game/presentation/life_board.dart';
import 'package:game_of_life/features/stats/data/player_stats.dart';
import 'package:game_of_life/features/stats/data/player_stats_repository.dart';
import 'package:game_of_life/features/stats/presentation/player_stats_controller.dart';
import 'package:game_of_life/providers.dart';

import '../../support/game_play_layout_test_support.dart';

void main() {
  for (final viewport in gameLayoutViewports) {
    testWidgets('online match uses ${viewport.name} geometry', (tester) async {
      configureGameViewport(tester, viewport);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            onlineRepositoryProvider.overrideWithValue(
              _MatchRepository(_activeMatch()),
            ),
          ],
          child: const MaterialApp(home: OnlineMatchScreen(matchId: 'match-1')),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('MOVE 1'), findsOneWidget);
      expect(find.text('vs Mika'), findsOneWidget);
      expect(find.byKey(const Key('game-view-settings')), findsOneWidget);
      expectGameLayoutGeometry(
        tester,
        viewport,
        boardKey: const Key('online-life-board'),
      );
    });
  }

  testWidgets('online taps preview locally and check submits the latest cell', (
    tester,
  ) async {
    configureGameViewport(tester, gameLayoutViewports.last);
    final repository = _MatchRepository(_activeMatch());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [onlineRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(home: OnlineMatchScreen(matchId: 'match-1')),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('life-cell-8-9')));
    await tester.pump();
    expect(repository.submissions, isEmpty);
    expect(find.byKey(const Key('commit-move')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('life-cell-0-0')));
    await tester.pump();
    expect(repository.submissions, isEmpty);

    await tester.tap(find.byKey(const Key('commit-move')));
    await tester.pump();
    await tester.pump();
    expect(repository.submissions, [(revision: 0, row: 0, column: 0)]);
    expect(find.byKey(const Key('commit-move')), findsNothing);
    final board = tester.widget<LifeBoard>(find.byType(LifeBoard));
    expect(board.lastMove, const engine.Coordinate(0, 0));
    expect(board.board.at(0, 0), engine.CellState.empty);
  });

  testWidgets('tapping the previewed online cell again submits it', (
    tester,
  ) async {
    configureGameViewport(tester, gameLayoutViewports.last);
    final repository = _MatchRepository(_activeMatch());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [onlineRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(home: OnlineMatchScreen(matchId: 'match-1')),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('life-cell-8-9')));
    await tester.pump();
    expect(repository.submissions, isEmpty);
    expect(
      find.textContaining('Tap the selected square again to confirm.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('life-cell-8-9')));
    await tester.pump();
    await tester.pump();

    expect(repository.submissions, [(revision: 0, row: 8, column: 9)]);
    expect(find.byKey(const Key('commit-move')), findsNothing);
  });

  testWidgets('terminal match refreshes the rated record exactly once', (
    tester,
  ) async {
    configureGameViewport(tester, gameLayoutViewports.last);
    final repository = _MatchRepository(_activeMatch());
    final stats = _CountingStatsRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          onlineRepositoryProvider.overrideWithValue(repository),
          playerStatsRepositoryProvider.overrideWithValue(stats),
          playerStatsControllerProvider.overrideWith((ref) {
            final controller = PlayerStatsController(stats);
            controller.connectAccount('player-a');
            return controller;
          }),
        ],
        child: const MaterialApp(home: OnlineMatchScreen(matchId: 'match-1')),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(stats.calls, 0);

    repository.match = _completedMatch(repository.match);
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    await tester.pump();

    expect(stats.calls, 1);
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    await tester.pump();
    expect(stats.calls, 1);
  });

  testWidgets('an initially terminal match refreshes a stale rated record', (
    tester,
  ) async {
    configureGameViewport(tester, gameLayoutViewports.last);
    final repository = _MatchRepository(_completedMatch(_activeMatch()));
    final stats = _CountingStatsRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          onlineRepositoryProvider.overrideWithValue(repository),
          playerStatsRepositoryProvider.overrideWithValue(stats),
          playerStatsControllerProvider.overrideWith((ref) {
            final controller = PlayerStatsController(stats);
            controller.connectAccount('player-a');
            return controller;
          }),
        ],
        child: const MaterialApp(home: OnlineMatchScreen(matchId: 'match-1')),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('MATCH COMPLETE'), findsOneWidget);
    expect(stats.calls, 1);
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    await tester.pump();
    expect(stats.calls, 1);
  });
}

OnlineMatch _activeMatch() {
  const players = [
    OnlinePlayer(
      id: 'black',
      username: 'black',
      displayName: 'Nora',
      color: engine.Player.black,
    ),
    OnlinePlayer(
      id: 'white',
      username: 'white',
      displayName: 'Mika',
      color: engine.Player.white,
    ),
  ];
  final state = const engine.GameEngine().initialState();
  return OnlineMatch(
    id: 'match-1',
    status: 'active',
    revision: 0,
    board: state.board,
    rules: state.rules,
    players: players,
    blackPopulation: state.board.population(engine.CellState.black),
    whitePopulation: state.board.population(engine.CellState.white),
    yourColor: engine.Player.black,
    nextPlayer: engine.Player.black,
  );
}

OnlineMatch _completedMatch(OnlineMatch match) => OnlineMatch(
  id: match.id,
  status: 'completed',
  revision: match.revision + 1,
  board: match.board,
  rules: match.rules,
  players: match.players,
  blackPopulation: match.blackPopulation,
  whitePopulation: match.whitePopulation,
  yourColor: match.yourColor,
  result: const {'winner': 'black'},
);

class _CountingStatsRepository implements PlayerStatsRepository {
  var calls = 0;

  @override
  Future<PlayerStats> getMyStats() async {
    calls++;
    return const PlayerStats(
      elo: 1216,
      victories: 1,
      totalGames: 1,
      kills: 3,
      losses: 0,
      draws: 0,
    );
  }
}

class _MatchRepository implements OnlineRepository {
  _MatchRepository(this.match);

  OnlineMatch match;
  final submissions = <({int revision, int row, int column})>[];

  @override
  Future<OnlineMatch?> getMatch(String id, {String? etag}) async => match;

  @override
  Future<OnlineMatch> submitMove(
    String id, {
    required int revision,
    required int row,
    required int column,
  }) async {
    submissions.add((revision: revision, row: row, column: column));
    final game = engine.GameState(
      rules: match.rules,
      board: match.board,
      ply: match.revision,
      revision: match.revision,
      toMove: match.nextPlayer,
      outcome: null,
    );
    final turn = const engine.GameEngine().applyMove(
      game,
      engine.GameMove(
        player: match.nextPlayer!,
        row: row,
        column: column,
        expectedRevision: revision,
      ),
    );
    return match = OnlineMatch(
      id: id,
      status: turn.state.isActive ? 'active' : 'completed',
      revision: turn.state.revision,
      board: turn.state.board,
      rules: turn.state.rules,
      players: match.players,
      blackPopulation: turn.state.blackPopulation,
      whitePopulation: turn.state.whitePopulation,
      yourColor: match.yourColor,
      nextPlayer: turn.state.toMove,
      lastMove: engine.Coordinate(row, column),
      result: turn.state.outcome?.toJson(),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
