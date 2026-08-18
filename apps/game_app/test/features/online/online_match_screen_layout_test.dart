import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:game_of_life/features/auth/data/auth_models.dart';
import 'package:game_of_life/features/auth/presentation/auth_controller.dart';
import 'package:game_of_life/features/game/presentation/life_board.dart';
import 'package:game_of_life/features/online/data/online_models.dart';
import 'package:game_of_life/features/online/data/online_repository.dart';
import 'package:game_of_life/features/online/presentation/online_match_screen.dart';
import 'package:game_of_life/features/stats/data/player_stats.dart';
import 'package:game_of_life/features/stats/data/player_stats_repository.dart';
import 'package:game_of_life/features/stats/presentation/player_stats_controller.dart';
import 'package:game_of_life/providers.dart';

import '../../fakes.dart';
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
    final auth = await _signedInAuthController();
    final stats = _CountingStatsRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith((ref) => auth),
          onlineRepositoryProvider.overrideWithValue(repository),
          playerStatsRepositoryProvider.overrideWithValue(stats),
          playerStatsControllerProvider.overrideWith(
            (ref) => PlayerStatsController(stats),
          ),
        ],
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
    final auth = await _signedInAuthController();
    final stats = _CountingStatsRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith((ref) => auth),
          onlineRepositoryProvider.overrideWithValue(repository),
          playerStatsRepositoryProvider.overrideWithValue(stats),
          playerStatsControllerProvider.overrideWith(
            (ref) => PlayerStatsController(stats),
          ),
        ],
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

  testWidgets(
    'a successful nonterminal move refreshes live evolution stats for the signed-in account',
    (tester) async {
      configureGameViewport(tester, gameLayoutViewports.last);
      final repository = _MatchRepository(_activeMatch());
      final auth = await _signedInAuthController();
      final stats = _CountingStatsRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith((ref) => auth),
            onlineRepositoryProvider.overrideWithValue(repository),
            playerStatsRepositoryProvider.overrideWithValue(stats),
            playerStatsControllerProvider.overrideWith(
              (ref) => PlayerStatsController(stats),
            ),
          ],
          child: const MaterialApp(home: OnlineMatchScreen(matchId: 'match-1')),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(stats.calls, 0);

      await tester.tap(find.byKey(const ValueKey('life-cell-8-9')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('commit-move')));
      await tester.pump();
      await tester.pump();

      expect(repository.match.isActive, isTrue);
      expect(stats.calls, 1);
      expect(
        ProviderScope.containerOf(
          tester.element(find.byType(OnlineMatchScreen)),
        ).read(playerStatsControllerProvider).stats?.kills,
        3,
      );
      expect(
        ProviderScope.containerOf(
          tester.element(find.byType(OnlineMatchScreen)),
        ).read(playerStatsControllerProvider).stats?.spawns,
        5,
      );
    },
  );

  testWidgets(
    'polling refreshes live evolution stats once per observed revision',
    (tester) async {
      configureGameViewport(tester, gameLayoutViewports.last);
      final repository = _MatchRepository(_activeMatch());
      final auth = await _signedInAuthController();
      final stats = _CountingStatsRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith((ref) => auth),
            onlineRepositoryProvider.overrideWithValue(repository),
            playerStatsRepositoryProvider.overrideWithValue(stats),
            playerStatsControllerProvider.overrideWith(
              (ref) => PlayerStatsController(stats),
            ),
          ],
          child: const MaterialApp(home: OnlineMatchScreen(matchId: 'match-1')),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(stats.calls, 0);

      await repository.submitMove('match-1', revision: 0, row: 8, column: 9);
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();
      await tester.pump();
      expect(stats.calls, 1);

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();
      await tester.pump();
      expect(stats.calls, 1);
    },
  );

  testWidgets('terminal match refreshes the rated record exactly once', (
    tester,
  ) async {
    configureGameViewport(tester, gameLayoutViewports.last);
    final repository = _MatchRepository(_activeMatch());
    final auth = await _signedInAuthController();
    final stats = _CountingStatsRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith((ref) => auth),
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
    final auth = await _signedInAuthController();
    final stats = _CountingStatsRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith((ref) => auth),
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

  testWidgets(
    'resignation refreshes terminal stats when the move revision does not advance',
    (tester) async {
      configureGameViewport(tester, gameLayoutViewports.last);
      final repository = _MatchRepository(_activeMatch());
      await repository.submitMove('match-1', revision: 0, row: 8, column: 9);
      final auth = await _signedInAuthController();
      final stats = _CountingStatsRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith((ref) => auth),
            onlineRepositoryProvider.overrideWithValue(repository),
            playerStatsRepositoryProvider.overrideWithValue(stats),
            playerStatsControllerProvider.overrideWith(
              (ref) => PlayerStatsController(stats),
            ),
          ],
          child: const MaterialApp(home: OnlineMatchScreen(matchId: 'match-1')),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(repository.match.revision, 1);
      expect(stats.calls, 1);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Resign match'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Resign'));
      await tester.pump();
      await tester.pump();

      expect(repository.match.status, 'completed');
      expect(repository.match.revision, 1);
      expect(stats.calls, 2);
    },
  );
}

Future<AuthController> _signedInAuthController() async {
  final repository = FakeAuthRepository()
    ..current = const AppUser(
      id: 'player-a',
      username: 'player-a',
      displayName: 'Nora',
    );
  final controller = AuthController(repository);
  await controller.restore();
  return controller;
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
      spawns: 5,
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
  Future<OnlineMatch> resign(String id, int revision) async {
    return match = OnlineMatch(
      id: match.id,
      status: 'completed',
      revision: match.revision,
      board: match.board,
      rules: match.rules,
      players: match.players,
      blackPopulation: match.blackPopulation,
      whitePopulation: match.whitePopulation,
      yourColor: match.yourColor,
      result: const {'type': 'win', 'winner': 'white', 'reason': 'resignation'},
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
