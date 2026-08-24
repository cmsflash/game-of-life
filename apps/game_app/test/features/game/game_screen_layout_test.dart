import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:game_of_life/features/game/data/game_view_settings_store.dart';
import 'package:game_of_life/features/game/data/local_game_store.dart';
import 'package:game_of_life/features/game/domain/game_session.dart';
import 'package:game_of_life/features/game/presentation/life_board.dart';
import 'package:game_of_life/features/game/presentation/local_game_screen.dart';
import 'package:game_of_life/features/game/presentation/local_games_controller.dart';
import 'package:game_of_life/providers.dart';

import '../../support/game_play_layout_test_support.dart';

void main() {
  for (final viewport in gameLayoutViewports) {
    testWidgets('local game uses ${viewport.name} geometry', (tester) async {
      configureGameViewport(tester, viewport);

      final controller = await _localController();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [localGamesProvider.overrideWith((ref) => controller)],
          child: const MaterialApp(home: LocalGameScreen(gameId: _gameId)),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('UNRATED · TURN 1'), findsOneWidget);
      expect(find.byKey(const Key('game-view-settings')), findsOneWidget);
      expect(find.byTooltip('Delete local game'), findsOneWidget);
      expectGameLayoutGeometry(
        tester,
        viewport,
        boardKey: const Key('local-life-board'),
      );
    });
  }

  testWidgets('cell taps preview and the player check commits once', (
    tester,
  ) async {
    configureGameViewport(tester, gameLayoutViewports.last);
    final controller = await _localController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localGamesProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: LocalGameScreen(gameId: _gameId)),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('life-cell-8-9')));
    await tester.pump();
    expect(controller.state.gameById(_gameId)!.game.revision, 0);
    expect(
      controller.state.gameById(_gameId)!.preview?.coordinate,
      const engine.Coordinate(8, 9),
    );
    expect(find.byKey(const Key('commit-move')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('life-cell-0-0')));
    await tester.pump();
    expect(controller.state.gameById(_gameId)!.game.revision, 0);
    expect(
      controller.state.gameById(_gameId)!.preview?.coordinate,
      const engine.Coordinate(0, 0),
    );

    await tester.tap(find.byKey(const Key('commit-move')));
    await tester.pump();
    expect(controller.state.gameById(_gameId)!.game.revision, 1);
    expect(
      controller.state.gameById(_gameId)!.game.toMove,
      engine.Player.white,
    );
    expect(
      controller.state.gameById(_gameId)!.lastMove,
      const engine.Coordinate(0, 0),
    );
    expect(controller.state.gameById(_gameId)!.preview, isNull);
    expect(find.byKey(const Key('commit-move')), findsNothing);
  });

  testWidgets('game view settings toggle death visualization', (tester) async {
    configureGameViewport(tester, gameLayoutViewports.last);
    final controller = await _localController();
    final settingsStore = MemoryGameViewSettingsStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localGamesProvider.overrideWith((ref) => controller),
          gameViewSettingsStoreProvider.overrideWithValue(settingsStore),
        ],
        child: const MaterialApp(home: LocalGameScreen(gameId: _gameId)),
      ),
    );
    await tester.pump();

    expect(
      tester.widget<LifeBoard>(find.byType(LifeBoard)).visualizePreviewDeaths,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('game-view-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Game view settings'), findsOneWidget);
    expect(find.text('Visualize deaths in preview'), findsOneWidget);

    await tester.tap(find.byKey(const Key('visualize-deaths-in-preview')));
    await tester.pump();

    expect(
      tester.widget<LifeBoard>(find.byType(LifeBoard)).visualizePreviewDeaths,
      isFalse,
    );
    expect(settingsStore.visualizeDeathsInPreview, isFalse);
  });

  testWidgets('tapping the previewed square again commits the local move', (
    tester,
  ) async {
    configureGameViewport(tester, gameLayoutViewports.last);
    final controller = await _localController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localGamesProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: LocalGameScreen(gameId: _gameId)),
      ),
    );
    await tester.pump();

    final cell = find.byKey(const ValueKey('life-cell-0-0'));
    await tester.tap(cell);
    await tester.pump();
    expect(controller.state.gameById(_gameId)!.game.revision, 0);

    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(controller.state.gameById(_gameId)!.game.revision, 1);
    expect(controller.state.gameById(_gameId)!.preview, isNull);
  });

  testWidgets('AI vs AI waits for one explicit next step per turn', (
    tester,
  ) async {
    configureGameViewport(tester, gameLayoutViewports.last);
    final controller = await _localController(
      config: const LocalGameConfig(
        blackName: 'Black AI',
        whiteName: 'White AI',
        blackParticipant: LocalParticipantType.ai,
        whiteParticipant: LocalParticipantType.ai,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localGamesProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: LocalGameScreen(gameId: _gameId)),
      ),
    );
    await tester.pump();

    expect(controller.state.gameById(_gameId)!.game.ply, 0);
    expect(tester.widget<LifeBoard>(find.byType(LifeBoard)).enabled, isFalse);
    expect(find.byKey(const Key('next-ai-step')), findsOneWidget);

    await tester.tap(find.byKey(const Key('next-ai-step')));
    await tester.pumpAndSettle();

    expect(controller.state.gameById(_gameId)!.game.ply, 1);
    expect(
      controller.state.gameById(_gameId)!.game.toMove,
      engine.Player.white,
    );
    expect(find.byKey(const Key('next-ai-step')), findsOneWidget);
  });

  testWidgets('delete action requires confirmation', (tester) async {
    configureGameViewport(tester, gameLayoutViewports.last);
    final controller = await _localController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localGamesProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: LocalGameScreen(gameId: _gameId)),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Delete local game'));
    await tester.pumpAndSettle();

    expect(find.text('Delete this local game?'), findsOneWidget);
    expect(find.text('Keep game'), findsOneWidget);
    expect(find.text('Delete game'), findsOneWidget);
    expect(controller.state.gameById(_gameId), isNotNull);
  });
}

const _gameId = 'local-widget-test';

Future<LocalGamesController> _localController({
  LocalGameConfig config = const LocalGameConfig(),
}) async {
  final controller = LocalGamesController(
    MemoryLocalGameStore(),
    idFactory: () => _gameId,
    clock: () => DateTime.utc(2026, 8, 14),
  );
  await controller.load();
  await controller.create(config);
  return controller;
}
