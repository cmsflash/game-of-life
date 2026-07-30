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

    test('places a cell and evolves exactly one turn', () {
      final controller = LocalGameController();
      controller.start(const LocalGameConfig());

      expect(controller.place(0, 0), isTrue);

      final session = controller.state!;
      expect(session.game.revision, 1);
      expect(session.game.toMove, engine.Player.white);
      expect(session.lastMove, const engine.Coordinate(0, 0));
      expect(session.game.board.at(0, 0), engine.CellState.empty);
      expect(session.lastDeaths, contains(const engine.Coordinate(0, 0)));
    });

    test('a surviving White move and its births render as White', () {
      final controller = LocalGameController();
      controller.start(const LocalGameConfig());
      expect(controller.place(0, 0), isTrue);

      expect(controller.place(8, 9), isTrue);

      final session = controller.state!;
      expect(session.game.revision, 2);
      expect(session.game.toMove, engine.Player.black);
      expect(session.lastMove, const engine.Coordinate(8, 9));
      expect(session.game.board.at(8, 9), engine.CellState.white);
      expect(session.lastBirths, contains(const engine.Coordinate(8, 10)));
      expect(session.game.board.at(8, 10), engine.CellState.white);
    });

    test('rejects placement on a living cell without advancing', () {
      final controller = LocalGameController();
      controller.start(const LocalGameConfig());

      expect(controller.place(9, 9), isFalse);
      expect(controller.state!.game.revision, 0);
      expect(controller.state!.error, isNotEmpty);
    });
  });
}
