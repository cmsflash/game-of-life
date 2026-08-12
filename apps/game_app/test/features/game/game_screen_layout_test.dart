import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:game_of_life/features/game/data/game_view_settings_store.dart';
import 'package:game_of_life/features/game/domain/game_session.dart';
import 'package:game_of_life/features/game/presentation/life_board.dart';
import 'package:game_of_life/features/game/presentation/local_game_screen.dart';
import 'package:game_of_life/providers.dart';

import '../../support/game_play_layout_test_support.dart';

void main() {
  for (final viewport in gameLayoutViewports) {
    testWidgets('local game uses ${viewport.name} geometry', (tester) async {
      configureGameViewport(tester, viewport);

      final controller = LocalGameController()..start(const LocalGameConfig());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [localGameProvider.overrideWith((ref) => controller)],
          child: const MaterialApp(home: LocalGameScreen()),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('TURN 1'), findsOneWidget);
      expect(find.byKey(const Key('game-view-settings')), findsOneWidget);
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
    final controller = LocalGameController()..start(const LocalGameConfig());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localGameProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: LocalGameScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('life-cell-8-9')));
    await tester.pump();
    expect(controller.state!.game.revision, 0);
    expect(
      controller.state!.preview?.coordinate,
      const engine.Coordinate(8, 9),
    );
    expect(find.byKey(const Key('commit-move')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('life-cell-0-0')));
    await tester.pump();
    expect(controller.state!.game.revision, 0);
    expect(
      controller.state!.preview?.coordinate,
      const engine.Coordinate(0, 0),
    );

    await tester.tap(find.byKey(const Key('commit-move')));
    await tester.pump();
    expect(controller.state!.game.revision, 1);
    expect(controller.state!.game.toMove, engine.Player.white);
    expect(controller.state!.lastMove, const engine.Coordinate(0, 0));
    expect(controller.state!.preview, isNull);
    expect(find.byKey(const Key('commit-move')), findsNothing);
  });

  testWidgets('game view settings toggle death visualization', (tester) async {
    configureGameViewport(tester, gameLayoutViewports.last);
    final controller = LocalGameController()..start(const LocalGameConfig());
    final settingsStore = MemoryGameViewSettingsStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localGameProvider.overrideWith((ref) => controller),
          gameViewSettingsStoreProvider.overrideWithValue(settingsStore),
        ],
        child: const MaterialApp(home: LocalGameScreen()),
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
}
