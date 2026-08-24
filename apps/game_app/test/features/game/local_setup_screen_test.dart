import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/features/game/data/local_game_store.dart';
import 'package:game_of_life/features/game/domain/game_session.dart';
import 'package:game_of_life/features/game/presentation/local_setup_screen.dart';
import 'package:game_of_life/features/game/presentation/local_games_controller.dart';
import 'package:game_of_life/providers.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('setup creates distinct saved games and opens each by ID', (
    tester,
  ) async {
    final ids = ['local-one', 'local-two'].iterator;
    final controller = LocalGamesController(
      MemoryLocalGameStore(),
      idFactory: () {
        ids.moveNext();
        return ids.current;
      },
      clock: () => DateTime.utc(2026, 8, 14),
    );
    await controller.load();
    final router = GoRouter(
      initialLocation: '/local/setup',
      routes: [
        GoRoute(
          path: '/local/setup',
          builder: (context, state) => const LocalSetupScreen(),
        ),
        GoRoute(
          path: '/local/game/:id',
          builder: (context, state) =>
              Scaffold(body: Text('Opened ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localGamesProvider.overrideWith((ref) => controller)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('local-game-title')),
      'Friday match',
    );
    await tester.enterText(find.byKey(const Key('local-black-name')), 'Ada');
    await tester.enterText(find.byKey(const Key('local-white-name')), 'Grace');
    await tester.ensureVisible(find.byKey(const Key('start-local-game')));
    await tester.tap(find.byKey(const Key('start-local-game')));
    await tester.pumpAndSettle();

    expect(find.text('Opened local-one'), findsOneWidget);
    expect(controller.state.games, hasLength(1));
    expect(controller.state.gameById('local-one')?.title, 'Friday match');
    expect(controller.state.gameById('local-one')?.opponentLabel, 'Grace');

    router.go('/local/setup');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('local-black-name')), 'Lin');
    await tester.enterText(find.byKey(const Key('local-white-name')), 'Kai');
    await tester.ensureVisible(find.byKey(const Key('start-local-game')));
    await tester.tap(find.byKey(const Key('start-local-game')));
    await tester.pumpAndSettle();

    expect(find.text('Opened local-two'), findsOneWidget);
    expect(controller.state.games, hasLength(2));
    expect(controller.state.gameById('local-one'), isNotNull);
    expect(controller.state.gameById('local-two')?.title, 'Lin vs Kai');
  });

  testWidgets('setup creates player vs AI with a configurable strategy mix', (
    tester,
  ) async {
    final controller = LocalGamesController(
      MemoryLocalGameStore(),
      idFactory: () => 'player-ai',
      clock: () => DateTime.utc(2026, 8, 14),
    );
    await controller.load();
    final router = _setupRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localGamesProvider.overrideWith((ref) => controller)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Player vs AI'));
    await tester.tap(find.text('Player vs AI'));
    await tester.pumpAndSettle();
    expect(find.text('AI strategy mix'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Greedy AI'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('ai-max-self-cells')), '20');
    await tester.enterText(
      find.byKey(const Key('ai-min-opponent-cells')),
      '30',
    );
    await tester.enterText(
      find.byKey(const Key('ai-max-cell-advantage')),
      '50',
    );
    await tester.pump();
    expect(find.text('Total: 100%'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('start-local-game')));
    await tester.tap(find.byKey(const Key('start-local-game')));
    await tester.pumpAndSettle();

    final game = controller.state.gameById('player-ai')!;
    expect(game.config.blackParticipant, LocalParticipantType.human);
    expect(game.config.whiteParticipant, LocalParticipantType.ai);
    expect(game.config.aiStrategyPercentages.maxSelfCells, 20);
    expect(game.config.aiStrategyPercentages.minOpponentCells, 30);
    expect(game.config.aiStrategyPercentages.maxCellAdvantage, 50);
    expect(game.game.ply, 0);
  });

  testWidgets('setup creates AI vs AI without automatically advancing', (
    tester,
  ) async {
    final controller = LocalGamesController(
      MemoryLocalGameStore(),
      idFactory: () => 'ai-ai',
      clock: () => DateTime.utc(2026, 8, 14),
    );
    await controller.load();
    final router = _setupRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localGamesProvider.overrideWith((ref) => controller)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('AI vs AI'));
    await tester.tap(find.text('AI vs AI'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('start-local-game')));
    await tester.tap(find.byKey(const Key('start-local-game')));
    await tester.pumpAndSettle();

    final game = controller.state.gameById('ai-ai')!;
    expect(game.config.isAiVsAi, isTrue);
    expect(game.game.ply, 0);
  });
}

GoRouter _setupRouter() => GoRouter(
  initialLocation: '/local/setup',
  routes: [
    GoRoute(
      path: '/local/setup',
      builder: (context, state) => const LocalSetupScreen(),
    ),
    GoRoute(
      path: '/local/game/:id',
      builder: (context, state) =>
          Scaffold(body: Text('Opened ${state.pathParameters['id']}')),
    ),
  ],
);
