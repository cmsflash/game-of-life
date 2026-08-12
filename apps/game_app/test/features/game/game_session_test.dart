import 'package:flutter_test/flutter_test.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:game_of_life/features/game/domain/game_session.dart';

void main() {
  group('LocalGameController', () {
    test('starts from the centered stable position with black first', () {
      final controller = LocalGameController();
      controller.start(const LocalGameConfig());

      final game = controller.state!.game;
      expect(game.blackPopulation, 2);
      expect(game.whitePopulation, 2);
      expect(game.toMove, engine.Player.black);
      expect(game.board.at(9, 9), engine.CellState.black);
      expect(game.board.at(9, 10), engine.CellState.white);
    });

    test('previews a cell without advancing the authoritative game', () {
      final controller = LocalGameController();
      controller.start(const LocalGameConfig());
      final before = controller.state!.game;

      expect(controller.consider(0, 0), isTrue);

      final session = controller.state!;
      expect(session.game, same(before));
      expect(session.game.revision, 0);
      expect(session.game.toMove, engine.Player.black);
      expect(session.lastMove, isNull);
      expect(session.preview?.coordinate, const engine.Coordinate(0, 0));
      expect(session.preview?.turn.state.revision, 1);
      expect(session.preview?.turn.state.toMove, engine.Player.white);
      expect(session.preview?.board.at(0, 0), engine.CellState.empty);
      expect(session.preview?.deaths, contains(const engine.Coordinate(0, 0)));
    });

    test('changing selection recomputes from the authoritative board', () {
      final controller = LocalGameController();
      controller.start(const LocalGameConfig());
      final initial = controller.state!.game;

      expect(controller.consider(8, 9), isTrue);
      final firstBoard = controller.state!.preview!.board;
      expect(controller.consider(0, 0), isTrue);

      final session = controller.state!;
      final expected = const engine.GameEngine().applyMove(
        initial,
        const engine.GameMove(
          player: engine.Player.black,
          row: 0,
          column: 0,
          expectedRevision: 0,
        ),
      );
      expect(session.game, same(initial));
      expect(session.preview!.coordinate, const engine.Coordinate(0, 0));
      expect(session.preview!.board, expected.state.board);
      expect(session.preview!.board, isNot(firstBoard));
    });

    test('commit applies only the latest preview and clears it', () {
      final controller = LocalGameController();
      controller.start(const LocalGameConfig());
      expect(controller.consider(8, 9), isTrue);
      expect(controller.consider(0, 0), isTrue);
      final expected = controller.state!.preview!;

      expect(controller.commit(), isTrue);

      final session = controller.state!;
      expect(session.game, same(expected.turn.state));
      expect(session.game.revision, 1);
      expect(session.lastMove, const engine.Coordinate(0, 0));
      expect(session.lastBirths, expected.births);
      expect(session.lastDeaths, expected.deaths);
      expect(session.preview, isNull);
      expect(controller.commit(), isFalse);
      expect(controller.state!.game.revision, 1);
    });

    test('a White-majority birth renders as White', () {
      final controller = LocalGameController();
      controller.start(const LocalGameConfig());
      expect(controller.consider(0, 0), isTrue);
      expect(controller.commit(), isTrue);

      expect(controller.consider(8, 9), isTrue);
      expect(controller.commit(), isTrue);

      final session = controller.state!;
      expect(session.game.revision, 2);
      expect(session.game.toMove, engine.Player.black);
      expect(session.lastMove, const engine.Coordinate(8, 9));
      expect(session.game.board.at(8, 9), engine.CellState.white);
      expect(session.lastBirths, contains(const engine.Coordinate(8, 10)));
      expect(session.game.board.at(8, 10), engine.CellState.white);
    });

    test('rejects an occupied cell without replacing a valid preview', () {
      final controller = LocalGameController();
      controller.start(const LocalGameConfig());
      expect(controller.consider(0, 0), isTrue);

      expect(controller.consider(9, 9), isFalse);
      expect(controller.state!.game.revision, 0);
      expect(controller.state!.error, isNotEmpty);
      expect(
        controller.state!.preview?.coordinate,
        const engine.Coordinate(0, 0),
      );
    });

    test(
      'cancelling a preview preserves the committed position and markers',
      () {
        final controller = LocalGameController();
        controller.start(const LocalGameConfig());
        expect(controller.consider(0, 0), isTrue);
        expect(controller.commit(), isTrue);
        final committed = controller.state!;

        expect(controller.consider(8, 9), isTrue);
        controller.cancelPreview();

        final session = controller.state!;
        expect(session.game, same(committed.game));
        expect(session.lastMove, committed.lastMove);
        expect(session.lastBirths, committed.lastBirths);
        expect(session.lastDeaths, committed.lastDeaths);
        expect(session.preview, isNull);
        expect(session.error, isNull);
      },
    );
  });
}
