import 'dart:math';

import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

void main() {
  const engine = GameEngine();
  Board evolveByMajority(Board board) => engine
      .evolve(board, birthOwnership: BirthOwnership.strictNeighborMajority)
      .board;

  test('optimized evolution matches an independent reference', () {
    final random = Random(20260720);
    for (var sample = 0; sample < 250; sample++) {
      final board = Board(
        rows: 8,
        columns: 9,
        cells: List.generate(
          72,
          (_) => CellState.values[random.nextInt(CellState.values.length)],
        ),
      );

      final actual = evolveByMajority(board);
      final expected = _referenceEvolution(board);

      expect(actual, expected, reason: 'random sample $sample');
    }
  });

  test('evolution is symmetric under color swapping', () {
    final random = Random(42);
    for (var sample = 0; sample < 100; sample++) {
      final board = Board(
        rows: 8,
        columns: 9,
        cells: List.generate(
          72,
          (_) => CellState.values[random.nextInt(CellState.values.length)],
        ),
      );

      final evolvedThenSwapped = _swapColors(evolveByMajority(board));
      final swappedThenEvolved = evolveByMajority(_swapColors(board));

      expect(swappedThenEvolved, evolvedThenSwapped);
    }
  });

  test('evolution is symmetric under horizontal reflection', () {
    final random = Random(99);
    for (var sample = 0; sample < 100; sample++) {
      final board = Board(
        rows: 8,
        columns: 9,
        cells: List.generate(
          72,
          (_) => CellState.values[random.nextInt(CellState.values.length)],
        ),
      );

      final evolvedThenReflected = _reflect(evolveByMajority(board));
      final reflectedThenEvolved = evolveByMajority(_reflect(board));

      expect(reflectedThenEvolved, evolvedThenReflected);
    }
  });
}

Board _referenceEvolution(Board board) {
  final next = <CellState>[];
  for (var row = 0; row < board.rows; row++) {
    for (var column = 0; column < board.columns; column++) {
      final neighbors = <CellState>[];
      for (var candidateRow = 0; candidateRow < board.rows; candidateRow++) {
        for (
          var candidateColumn = 0;
          candidateColumn < board.columns;
          candidateColumn++
        ) {
          if (candidateRow == row && candidateColumn == column) continue;
          if ((candidateRow - row).abs() <= 1 &&
              (candidateColumn - column).abs() <= 1) {
            final cell = board.at(candidateRow, candidateColumn);
            if (cell != CellState.empty) neighbors.add(cell);
          }
        }
      }
      final current = board.at(row, column);
      if (current != CellState.empty) {
        next.add(
          neighbors.length == 2 || neighbors.length == 3
              ? current
              : CellState.empty,
        );
      } else if (neighbors.length != 3) {
        next.add(CellState.empty);
      } else {
        final black = neighbors.where((cell) => cell == CellState.black).length;
        next.add(black >= 2 ? CellState.black : CellState.white);
      }
    }
  }
  return Board(rows: board.rows, columns: board.columns, cells: next);
}

Board _swapColors(Board board) => Board(
  rows: board.rows,
  columns: board.columns,
  cells: board.cells.map(
    (cell) => switch (cell) {
      CellState.empty => CellState.empty,
      CellState.black => CellState.white,
      CellState.white => CellState.black,
    },
  ),
);

Board _reflect(Board board) {
  final cells = <CellState>[];
  for (var row = 0; row < board.rows; row++) {
    for (var column = 0; column < board.columns; column++) {
      cells.add(board.at(row, board.columns - column - 1));
    }
  }
  return Board(rows: board.rows, columns: board.columns, cells: cells);
}
