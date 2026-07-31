import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/features/game/domain/game_session.dart';
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
      expectGameLayoutGeometry(
        tester,
        viewport,
        boardKey: const Key('local-life-board'),
      );
    });
  }
}
