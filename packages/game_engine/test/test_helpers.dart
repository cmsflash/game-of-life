import 'package:game_engine/game_engine.dart';

Board boardWith(
  Map<Coordinate, CellState> occupied, {
  int rows = GameRules.rows,
  int columns = GameRules.columns,
}) {
  final cells = List<CellState>.filled(rows * columns, CellState.empty);
  for (final entry in occupied.entries) {
    cells[entry.key.indexFor(columns)] = entry.value;
  }
  return Board(rows: rows, columns: columns, cells: cells);
}

Set<Coordinate> coordinatesOf(Board board, CellState state) {
  final coordinates = <Coordinate>{};
  for (var row = 0; row < board.rows; row++) {
    for (var column = 0; column < board.columns; column++) {
      if (board.at(row, column) == state) {
        coordinates.add(Coordinate(row, column));
      }
    }
  }
  return coordinates;
}

GameState activeState(
  Board board, {
  Player toMove = Player.black,
  GameRules? rules,
  int ply = 0,
}) => GameState(
  rules: rules ?? GameRules.standard(),
  board: board,
  ply: ply,
  revision: ply,
  toMove: toMove,
  outcome: null,
);
