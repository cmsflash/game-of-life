import 'board.dart';
import 'result.dart';
import 'rules.dart';
import 'state.dart';

/// One distinct legal successor, represented by its first row-major move.
///
/// Search does not need the animation events produced by [TurnResult]. Apply
/// [move] with [GameEngine.applyMove] when committing it to a played game.
final class SearchSuccessor {
  const SearchSuccessor({required this.move, required this.state});

  final GameMove move;
  final GameState state;
}

final class GameEngine {
  const GameEngine();

  GameState initialState([GameRules? rules]) {
    final resolvedRules = rules ?? GameRules.standard();
    var board = Board.empty(rows: GameRules.rows, columns: GameRules.columns);
    board = board.withCell(const Coordinate(9, 9), CellState.black);
    board = board.withCell(const Coordinate(9, 10), CellState.white);
    board = board.withCell(const Coordinate(10, 9), CellState.white);
    board = board.withCell(const Coordinate(10, 10), CellState.black);
    return GameState(
      rules: resolvedRules,
      board: board,
      ply: 0,
      revision: 0,
      toMove: Player.black,
      outcome: null,
    );
  }

  MoveValidation validateMove(GameState state, GameMove move) {
    if (!state.isActive) {
      return const MoveValidation.invalid(
        MoveErrorCode.gameOver,
        'the game is already complete',
      );
    }
    if (move.player != state.toMove) {
      return MoveValidation.invalid(
        MoveErrorCode.wrongPlayer,
        'expected ${state.toMove!.name}, received ${move.player.name}',
      );
    }
    if (move.expectedRevision != state.revision) {
      return MoveValidation.invalid(
        MoveErrorCode.staleRevision,
        'expected revision ${state.revision}, received '
        '${move.expectedRevision}',
      );
    }
    if (!state.board.contains(move.coordinate)) {
      return MoveValidation.invalid(
        MoveErrorCode.outOfBounds,
        'coordinate ${move.coordinate} is outside the board',
      );
    }
    if (state.board.atCoordinate(move.coordinate) != CellState.empty) {
      return MoveValidation.invalid(
        MoveErrorCode.occupied,
        'coordinate ${move.coordinate} is occupied',
      );
    }
    return const MoveValidation.valid();
  }

  TurnResult applyMove(GameState state, GameMove move) {
    final validation = validateMove(state, move);
    if (!validation.isValid) {
      throw GameRuleViolation(validation.code!, validation.message!);
    }

    final postPlacement = state.board.withCell(
      move.coordinate,
      move.player.cell,
    );
    final evolution = evolve(postPlacement);
    final nextPly = state.ply + 1;
    final outcome = evaluateOutcome(evolution.board, state.rules, ply: nextPly);
    final nextState = GameState(
      rules: state.rules,
      board: evolution.board,
      ply: nextPly,
      revision: state.revision + 1,
      toMove: outcome == null ? move.player.opponent : null,
      outcome: outcome,
    );
    return TurnResult(
      state: nextState,
      delta: TurnDelta(
        placement: PlacementEvent(
          coordinate: move.coordinate,
          player: move.player,
        ),
        evolution: evolution.delta,
      ),
    );
  }

  ApplyMoveResult tryApplyMove(GameState state, GameMove move) {
    final validation = validateMove(state, move);
    if (!validation.isValid) return RejectedMove(validation);
    return AppliedMove(applyMove(state, move));
  }

  /// Evolves [postPlacementBoard] once using simultaneous B3/S23 rules.
  ///
  /// A newborn cell takes the strict majority color of its three live
  /// neighbors. Because a birth always has exactly three neighbors, a tie is
  /// impossible.
  EvolutionResult evolve(Board postPlacementBoard) {
    final nextCells = List<CellState>.filled(
      postPlacementBoard.length,
      CellState.empty,
    );
    final births = <CellBirth>[];
    final deaths = <CellDeath>[];

    for (var row = 0; row < postPlacementBoard.rows; row++) {
      for (var column = 0; column < postPlacementBoard.columns; column++) {
        var blackNeighbors = 0;
        var whiteNeighbors = 0;
        for (var rowDelta = -1; rowDelta <= 1; rowDelta++) {
          for (var columnDelta = -1; columnDelta <= 1; columnDelta++) {
            if (rowDelta == 0 && columnDelta == 0) continue;
            final neighborRow = row + rowDelta;
            final neighborColumn = column + columnDelta;
            if (neighborRow < 0 ||
                neighborRow >= postPlacementBoard.rows ||
                neighborColumn < 0 ||
                neighborColumn >= postPlacementBoard.columns) {
              continue;
            }
            switch (postPlacementBoard.at(neighborRow, neighborColumn)) {
              case CellState.black:
                blackNeighbors++;
              case CellState.white:
                whiteNeighbors++;
              case CellState.empty:
                break;
            }
          }
        }

        final current = postPlacementBoard.at(row, column);
        final next = _nextCell(current, blackNeighbors, whiteNeighbors);
        final coordinate = Coordinate(row, column);
        nextCells[coordinate.indexFor(postPlacementBoard.columns)] = next;
        if (current == CellState.empty && next != CellState.empty) {
          births.add(
            CellBirth(coordinate: coordinate, player: playerForCell(next)),
          );
        } else if (current != CellState.empty && next == CellState.empty) {
          deaths.add(
            CellDeath(coordinate: coordinate, player: playerForCell(current)),
          );
        }
      }
    }

    return EvolutionResult(
      board: Board(
        rows: postPlacementBoard.rows,
        columns: postPlacementBoard.columns,
        cells: nextCells,
      ),
      delta: EvolutionDelta(births: births, deaths: deaths),
    );
  }

  List<Coordinate> legalMoves(GameState state) =>
      state.isActive ? state.board.emptyCoordinates() : const [];

  /// Lazily yields exactly one representative of every legal successor state.
  ///
  /// A placement changes only its own cell and its eight neighbors in the next
  /// generation. Compute the unmodified board's evolution once, then describe
  /// each candidate by its exact changes to that common base. Equal signatures
  /// are discarded before allocating a successor board. An ineffectual distant
  /// placement still keeps its first legal representative.
  Iterable<SearchSuccessor> searchSuccessors(GameState state) sync* {
    if (!state.isActive) return;
    final board = state.board;
    final cells = board.cells;
    final rows = board.rows;
    final columns = board.columns;
    final blackNeighbors = List<int>.filled(board.length, 0);
    final whiteNeighbors = List<int>.filled(board.length, 0);
    for (var index = 0; index < cells.length; index++) {
      final cell = cells[index];
      if (cell == CellState.empty) continue;
      final counts = cell == CellState.black ? blackNeighbors : whiteNeighbors;
      final row = index ~/ columns;
      final column = index % columns;
      for (var rowDelta = -1; rowDelta <= 1; rowDelta++) {
        final neighborRow = row + rowDelta;
        if (neighborRow < 0 || neighborRow >= rows) continue;
        for (var columnDelta = -1; columnDelta <= 1; columnDelta++) {
          if (rowDelta == 0 && columnDelta == 0) continue;
          final neighborColumn = column + columnDelta;
          if (neighborColumn < 0 || neighborColumn >= columns) continue;
          counts[neighborRow * columns + neighborColumn]++;
        }
      }
    }
    final base = List<CellState>.generate(
      board.length,
      (index) =>
          _nextCell(cells[index], blackNeighbors[index], whiteNeighbors[index]),
      growable: false,
    );
    final player = state.toMove!;
    final seen = <_SuccessorSignature>{};
    for (var placement = 0; placement < cells.length; placement++) {
      if (cells[placement] != CellState.empty) continue;
      final row = placement ~/ columns;
      final column = placement % columns;
      final changes = <int>[];
      for (var rowDelta = -1; rowDelta <= 1; rowDelta++) {
        final affectedRow = row + rowDelta;
        if (affectedRow < 0 || affectedRow >= rows) continue;
        for (var columnDelta = -1; columnDelta <= 1; columnDelta++) {
          final affectedColumn = column + columnDelta;
          if (affectedColumn < 0 || affectedColumn >= columns) continue;
          final index = affectedRow * columns + affectedColumn;
          final isPlacement = index == placement;
          final next = _nextCell(
            isPlacement ? player.cell : cells[index],
            blackNeighbors[index] +
                (!isPlacement && player == Player.black ? 1 : 0),
            whiteNeighbors[index] +
                (!isPlacement && player == Player.white ? 1 : 0),
          );
          if (next != base[index]) {
            // Row-major (index, value) pairs form an exact board signature.
            changes.add(index * CellState.values.length + next.wireValue);
          }
        }
      }
      if (!seen.add(_SuccessorSignature(changes))) continue;
      final nextCells = List<CellState>.of(base);
      for (final change in changes) {
        nextCells[change ~/ CellState.values.length] =
            CellState.values[change % CellState.values.length];
      }
      final nextBoard = Board(rows: rows, columns: columns, cells: nextCells);
      final nextPly = state.ply + 1;
      final outcome = evaluateOutcome(nextBoard, state.rules, ply: nextPly);
      yield SearchSuccessor(
        move: GameMove(
          player: player,
          row: row,
          column: column,
          expectedRevision: state.revision,
        ),
        state: GameState(
          rules: state.rules,
          board: nextBoard,
          ply: nextPly,
          revision: state.revision + 1,
          toMove: outcome == null ? player.opponent : null,
          outcome: outcome,
        ),
      );
    }
  }

  GameOutcome? evaluateOutcome(
    Board board,
    GameRules rules, {
    required int ply,
  }) {
    final blackPopulation = board.population(CellState.black);
    final whitePopulation = board.population(CellState.white);

    if (blackPopulation == 0 && whitePopulation == 0) {
      return GameOutcome.draw(
        reason: OutcomeReason.mutualExtinction,
        blackPopulation: 0,
        whitePopulation: 0,
      );
    }
    if (blackPopulation == 0) {
      return GameOutcome.win(
        winner: Player.white,
        reason: OutcomeReason.elimination,
        blackPopulation: blackPopulation,
        whitePopulation: whitePopulation,
      );
    }
    if (whitePopulation == 0) {
      return GameOutcome.win(
        winner: Player.black,
        reason: OutcomeReason.elimination,
        blackPopulation: blackPopulation,
        whitePopulation: whitePopulation,
      );
    }

    switch (rules.victory) {
      case EliminationVictory():
        break;
      case PopulationTargetVictory(:final target):
        final blackReached = blackPopulation >= target;
        final whiteReached = whitePopulation >= target;
        if (blackReached && whiteReached) {
          return GameOutcome.draw(
            reason: OutcomeReason.simultaneousTarget,
            blackPopulation: blackPopulation,
            whitePopulation: whitePopulation,
          );
        }
        if (blackReached || whiteReached) {
          return GameOutcome.win(
            winner: blackReached ? Player.black : Player.white,
            reason: OutcomeReason.populationTarget,
            blackPopulation: blackPopulation,
            whitePopulation: whitePopulation,
          );
        }
      case TurnLimitPopulationVictory(:final maxPlies):
        if (ply >= maxPlies) {
          if (blackPopulation == whitePopulation) {
            return GameOutcome.draw(
              reason: OutcomeReason.turnLimitTie,
              blackPopulation: blackPopulation,
              whitePopulation: whitePopulation,
            );
          }
          return GameOutcome.win(
            winner: blackPopulation > whitePopulation
                ? Player.black
                : Player.white,
            reason: OutcomeReason.turnLimitPopulation,
            blackPopulation: blackPopulation,
            whitePopulation: whitePopulation,
          );
        }
    }

    if (!board.hasEmptyCell) {
      return GameOutcome.draw(
        reason: OutcomeReason.noLegalMoves,
        blackPopulation: blackPopulation,
        whitePopulation: whitePopulation,
      );
    }
    return null;
  }

  GameState replay(
    Iterable<GameMove> moves, {
    GameRules? rules,
    GameState? initial,
  }) {
    if (rules != null && initial != null && rules != initial.rules) {
      throw ArgumentError('rules and initial state rules do not match');
    }
    var state = initial ?? initialState(rules);
    for (final move in moves) {
      state = applyMove(state, move).state;
    }
    return state;
  }
}

CellState _nextCell(CellState current, int blackNeighbors, int whiteNeighbors) {
  final liveNeighbors = blackNeighbors + whiteNeighbors;
  return switch (current) {
    CellState.black || CellState.white =>
      liveNeighbors == 2 || liveNeighbors == 3 ? current : CellState.empty,
    CellState.empty =>
      liveNeighbors == 3
          ? (blackNeighbors > whiteNeighbors
                ? CellState.black
                : CellState.white)
          : CellState.empty,
  };
}

final class _SuccessorSignature {
  const _SuccessorSignature(this.changes);

  final List<int> changes;

  @override
  bool operator ==(Object other) {
    if (other is! _SuccessorSignature ||
        changes.length != other.changes.length) {
      return false;
    }
    for (var index = 0; index < changes.length; index++) {
      if (changes[index] != other.changes[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(changes);
}
