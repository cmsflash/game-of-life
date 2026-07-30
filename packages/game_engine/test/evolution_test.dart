import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  const engine = GameEngine();
  EvolutionResult evolve(Board board, {Player movingPlayer = Player.black}) =>
      engine.evolve(board, movingPlayer: movingPlayer);

  group('initial state', () {
    test('is the stable centered diagonal-owned block', () {
      final state = engine.initialState();

      expect(state.board.rows, 20);
      expect(state.board.columns, 20);
      expect(coordinatesOf(state.board, CellState.black), {
        const Coordinate(9, 9),
        const Coordinate(10, 10),
      });
      expect(coordinatesOf(state.board, CellState.white), {
        const Coordinate(9, 10),
        const Coordinate(10, 9),
      });
      expect(state.blackPopulation, 2);
      expect(state.whitePopulation, 2);
      expect(state.toMove, Player.black);
      expect(state.ply, 0);
      expect(state.revision, 0);
      expect(state.outcome, isNull);
      expect(evolve(state.board).board, state.board);
    });
  });

  group('B3/S23 simultaneous evolution', () {
    test('underpopulation, survival, and overpopulation', () {
      final underpopulated = boardWith({
        const Coordinate(5, 5): CellState.black,
        const Coordinate(5, 6): CellState.white,
      });
      expect(evolve(underpopulated).board.at(5, 5), CellState.empty);

      final twoNeighbors = boardWith({
        const Coordinate(5, 5): CellState.black,
        const Coordinate(4, 4): CellState.white,
        const Coordinate(4, 5): CellState.white,
      });
      expect(evolve(twoNeighbors).board.at(5, 5), CellState.black);

      final threeNeighbors = boardWith({
        const Coordinate(5, 5): CellState.white,
        const Coordinate(4, 4): CellState.black,
        const Coordinate(4, 5): CellState.black,
        const Coordinate(4, 6): CellState.black,
      });
      expect(evolve(threeNeighbors).board.at(5, 5), CellState.white);

      final fourNeighbors = boardWith({
        const Coordinate(5, 5): CellState.black,
        const Coordinate(4, 4): CellState.white,
        const Coordinate(4, 5): CellState.white,
        const Coordinate(4, 6): CellState.white,
        const Coordinate(5, 4): CellState.white,
      });
      expect(evolve(fourNeighbors).board.at(5, 5), CellState.empty);
    });

    test('blinker proves updates are simultaneous', () {
      final horizontal = boardWith({
        const Coordinate(5, 4): CellState.black,
        const Coordinate(5, 5): CellState.black,
        const Coordinate(5, 6): CellState.black,
      });

      final next = evolve(horizontal).board;

      expect(coordinatesOf(next, CellState.black), {
        const Coordinate(4, 5),
        const Coordinate(5, 5),
        const Coordinate(6, 5),
      });
    });

    test('uses finite dead boundaries and never wraps', () {
      final board = boardWith({
        const Coordinate(0, 1): CellState.black,
        const Coordinate(1, 0): CellState.black,
        const Coordinate(19, 19): CellState.black,
      });

      expect(evolve(board).board.at(0, 0), CellState.empty);
    });

    test('assigns every birth to the moving player', () {
      final board = boardWith({
        const Coordinate(4, 4): CellState.black,
        const Coordinate(4, 5): CellState.black,
        const Coordinate(4, 6): CellState.white,
      });

      final blackResult = evolve(board);
      final whiteResult = evolve(board, movingPlayer: Player.white);

      expect(blackResult.board.at(5, 5), CellState.black);
      expect(whiteResult.board.at(5, 5), CellState.white);
      expect(
        whiteResult.delta.births,
        contains(
          isA<CellBirth>()
              .having(
                (birth) => birth.coordinate,
                'coordinate',
                const Coordinate(5, 5),
              )
              .having((birth) => birth.player, 'player', Player.white),
        ),
      );
    });

    test('survivors retain ownership despite opposite-color neighbors', () {
      final board = boardWith({
        const Coordinate(5, 5): CellState.white,
        const Coordinate(4, 4): CellState.black,
        const Coordinate(4, 5): CellState.black,
      });

      expect(evolve(board).board.at(5, 5), CellState.white);
    });

    test('reports row-major births and deaths', () {
      final board = boardWith({
        const Coordinate(5, 4): CellState.black,
        const Coordinate(5, 5): CellState.black,
        const Coordinate(5, 6): CellState.black,
      });

      final delta = evolve(board).delta;

      expect(delta.births.map((event) => event.coordinate), [
        const Coordinate(4, 5),
        const Coordinate(6, 5),
      ]);
      expect(delta.deaths.map((event) => event.coordinate), [
        const Coordinate(5, 4),
        const Coordinate(5, 6),
      ]);
    });
  });
}
