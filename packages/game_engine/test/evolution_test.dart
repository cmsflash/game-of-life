import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  const engine = GameEngine();

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
      expect(engine.evolve(state.board).board, state.board);
    });
  });

  group('B3/S23 simultaneous evolution', () {
    test('underpopulation, survival, and overpopulation', () {
      final underpopulated = boardWith({
        const Coordinate(5, 5): CellState.black,
        const Coordinate(5, 6): CellState.white,
      });
      expect(engine.evolve(underpopulated).board.at(5, 5), CellState.empty);

      final twoNeighbors = boardWith({
        const Coordinate(5, 5): CellState.black,
        const Coordinate(4, 4): CellState.white,
        const Coordinate(4, 5): CellState.white,
      });
      expect(engine.evolve(twoNeighbors).board.at(5, 5), CellState.black);

      final threeNeighbors = boardWith({
        const Coordinate(5, 5): CellState.white,
        const Coordinate(4, 4): CellState.black,
        const Coordinate(4, 5): CellState.black,
        const Coordinate(4, 6): CellState.black,
      });
      expect(engine.evolve(threeNeighbors).board.at(5, 5), CellState.white);

      final fourNeighbors = boardWith({
        const Coordinate(5, 5): CellState.black,
        const Coordinate(4, 4): CellState.white,
        const Coordinate(4, 5): CellState.white,
        const Coordinate(4, 6): CellState.white,
        const Coordinate(5, 4): CellState.white,
      });
      expect(engine.evolve(fourNeighbors).board.at(5, 5), CellState.empty);
    });

    test('blinker proves updates are simultaneous', () {
      final horizontal = boardWith({
        const Coordinate(5, 4): CellState.black,
        const Coordinate(5, 5): CellState.black,
        const Coordinate(5, 6): CellState.black,
      });

      final next = engine.evolve(horizontal).board;

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

      expect(engine.evolve(board).board.at(0, 0), CellState.empty);
    });

    test('birth color is the strict majority of three neighbors', () {
      Board birthBoard(CellState first, CellState second, CellState third) =>
          boardWith({
            const Coordinate(4, 4): first,
            const Coordinate(4, 5): second,
            const Coordinate(4, 6): third,
          });

      expect(
        engine
            .evolve(
              birthBoard(CellState.black, CellState.black, CellState.black),
            )
            .board
            .at(5, 5),
        CellState.black,
      );
      expect(
        engine
            .evolve(
              birthBoard(CellState.black, CellState.black, CellState.white),
            )
            .board
            .at(5, 5),
        CellState.black,
      );
      expect(
        engine
            .evolve(
              birthBoard(CellState.black, CellState.white, CellState.white),
            )
            .board
            .at(5, 5),
        CellState.white,
      );
      expect(
        engine
            .evolve(
              birthBoard(CellState.white, CellState.white, CellState.white),
            )
            .board
            .at(5, 5),
        CellState.white,
      );
    });

    test('survivors retain ownership despite opposite-color neighbors', () {
      final board = boardWith({
        const Coordinate(5, 5): CellState.white,
        const Coordinate(4, 4): CellState.black,
        const Coordinate(4, 5): CellState.black,
      });

      expect(engine.evolve(board).board.at(5, 5), CellState.white);
    });

    test('reports row-major births and deaths', () {
      final board = boardWith({
        const Coordinate(5, 4): CellState.black,
        const Coordinate(5, 5): CellState.black,
        const Coordinate(5, 6): CellState.black,
      });

      final delta = engine.evolve(board).delta;

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
