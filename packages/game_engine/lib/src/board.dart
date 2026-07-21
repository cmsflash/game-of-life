import 'dart:collection';

import 'json_utils.dart';

enum CellState {
  empty(0),
  black(1),
  white(2);

  const CellState(this.wireValue);

  final int wireValue;

  static CellState fromWireValue(Object? value) {
    if (value is! int) {
      throw const FormatException('cell value must be an integer');
    }
    return switch (value) {
      0 => CellState.empty,
      1 => CellState.black,
      2 => CellState.white,
      _ => throw FormatException('unsupported cell value: $value'),
    };
  }
}

enum Player {
  black,
  white;

  Player get opponent => this == Player.black ? Player.white : Player.black;

  CellState get cell =>
      this == Player.black ? CellState.black : CellState.white;

  static Player fromJson(Object? value) {
    return switch (value) {
      'black' => Player.black,
      'white' => Player.white,
      _ => throw FormatException('unsupported player: $value'),
    };
  }
}

Player playerForCell(CellState cell) {
  return switch (cell) {
    CellState.black => Player.black,
    CellState.white => Player.white,
    CellState.empty => throw const FormatException(
      'an empty cell has no owning player',
    ),
  };
}

final class Coordinate implements Comparable<Coordinate> {
  const Coordinate(this.row, this.column);

  final int row;
  final int column;

  int indexFor(int columns) => row * columns + column;

  Map<String, Object?> toJson() => {'row': row, 'column': column};

  factory Coordinate.fromJson(Object? value) {
    final json = expectJsonObject(value, 'coordinate');
    expectExactKeys(json, {'row', 'column'}, name: 'coordinate');
    return Coordinate(
      expectJsonInt(json['row'], 'coordinate.row'),
      expectJsonInt(json['column'], 'coordinate.column'),
    );
  }

  @override
  int compareTo(Coordinate other) {
    final rowComparison = row.compareTo(other.row);
    return rowComparison != 0 ? rowComparison : column.compareTo(other.column);
  }

  @override
  bool operator ==(Object other) =>
      other is Coordinate && row == other.row && column == other.column;

  @override
  int get hashCode => Object.hash(row, column);

  @override
  String toString() => '($row,$column)';
}

final class Board {
  Board({
    required this.rows,
    required this.columns,
    required Iterable<CellState> cells,
  }) : _cells = List<CellState>.unmodifiable(cells) {
    if (rows <= 0 || columns <= 0) {
      throw ArgumentError('board dimensions must be positive');
    }
    if (_cells.length != rows * columns) {
      throw ArgumentError(
        'expected ${rows * columns} cells, received ${_cells.length}',
      );
    }
  }

  factory Board.empty({required int rows, required int columns}) => Board(
    rows: rows,
    columns: columns,
    cells: List<CellState>.filled(rows * columns, CellState.empty),
  );

  factory Board.fromJson(Object? value) {
    final json = expectJsonObject(value, 'board');
    expectExactKeys(json, {'rows', 'columns', 'cells'}, name: 'board');
    final cells = expectJsonList(
      json['cells'],
      'board.cells',
    ).map(CellState.fromWireValue);
    return Board(
      rows: expectJsonInt(json['rows'], 'board.rows'),
      columns: expectJsonInt(json['columns'], 'board.columns'),
      cells: cells,
    );
  }

  final int rows;
  final int columns;
  final List<CellState> _cells;

  UnmodifiableListView<CellState> get cells => UnmodifiableListView(_cells);

  int get length => _cells.length;

  bool contains(Coordinate coordinate) =>
      coordinate.row >= 0 &&
      coordinate.row < rows &&
      coordinate.column >= 0 &&
      coordinate.column < columns;

  CellState at(int row, int column) {
    final coordinate = Coordinate(row, column);
    if (!contains(coordinate)) {
      throw RangeError('coordinate $coordinate is outside the board');
    }
    return _cells[coordinate.indexFor(columns)];
  }

  CellState atCoordinate(Coordinate coordinate) =>
      at(coordinate.row, coordinate.column);

  Board withCell(Coordinate coordinate, CellState value) {
    if (!contains(coordinate)) {
      throw RangeError('coordinate $coordinate is outside the board');
    }
    final next = List<CellState>.from(_cells);
    next[coordinate.indexFor(columns)] = value;
    return Board(rows: rows, columns: columns, cells: next);
  }

  int population(CellState state) =>
      _cells.where((cell) => cell == state).length;

  int populationFor(Player player) => population(player.cell);

  bool get hasEmptyCell => _cells.contains(CellState.empty);

  List<Coordinate> emptyCoordinates() {
    final result = <Coordinate>[];
    for (var index = 0; index < _cells.length; index++) {
      if (_cells[index] == CellState.empty) {
        result.add(Coordinate(index ~/ columns, index % columns));
      }
    }
    return List<Coordinate>.unmodifiable(result);
  }

  Map<String, Object?> toJson() => {
    'rows': rows,
    'columns': columns,
    'cells': _cells.map((cell) => cell.wireValue).toList(growable: false),
  };

  @override
  bool operator ==(Object other) =>
      other is Board &&
      rows == other.rows &&
      columns == other.columns &&
      listEquals(_cells, other._cells);

  @override
  int get hashCode => Object.hash(rows, columns, hashList(_cells));

  @override
  String toString() => 'Board(${rows}x$columns)';
}

final class GameMove {
  const GameMove({
    required this.player,
    required this.row,
    required this.column,
    required this.expectedRevision,
  });

  final Player player;
  final int row;
  final int column;
  final int expectedRevision;

  Coordinate get coordinate => Coordinate(row, column);

  Map<String, Object?> toJson() => {
    'player': player.name,
    'row': row,
    'column': column,
    'expectedRevision': expectedRevision,
  };

  factory GameMove.fromJson(Object? value) {
    final json = expectJsonObject(value, 'move');
    expectExactKeys(json, {
      'player',
      'row',
      'column',
      'expectedRevision',
    }, name: 'move');
    return GameMove(
      player: Player.fromJson(json['player']),
      row: expectJsonInt(json['row'], 'move.row'),
      column: expectJsonInt(json['column'], 'move.column'),
      expectedRevision: expectJsonInt(
        json['expectedRevision'],
        'move.expectedRevision',
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GameMove &&
      player == other.player &&
      row == other.row &&
      column == other.column &&
      expectedRevision == other.expectedRevision;

  @override
  int get hashCode => Object.hash(player, row, column, expectedRevision);
}
