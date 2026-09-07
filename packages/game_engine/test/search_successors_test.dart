import 'dart:math';

import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  const engine = GameEngine();

  test('preserves row-major representatives, including ineffectual moves', () {
    final state = engine.initialState();
    final successors = engine.searchSuccessors(state);

    expect(successors.first.move.coordinate, const Coordinate(0, 0));
    expect(successors.first.state.board, state.board);
    expect(successors.length, 25);
    _expectCanonicalSuccessors(state);

    // Early termination does not consume or mutate the iterable or parent.
    expect(successors.take(1).single.state, successors.first.state);
    expect(state, engine.initialState());
    _expectCanonicalSuccessors(state);
  });

  test(
    'matches every legal move on sparse and dense boards for both colors',
    () {
      final random = Random(90210);
      for (final density in [0.02, 0.1, 0.3, 0.55, 0.8, 0.97]) {
        for (final player in Player.values) {
          final cells = List<CellState>.generate(
            GameRules.cellCount,
            (_) => random.nextDouble() < density
                ? (random.nextBool() ? CellState.black : CellState.white)
                : CellState.empty,
          );
          // Exercise every corner as a legal placement even on dense boards.
          for (final index in [0, 19, 380, 399]) {
            cells[index] = CellState.empty;
          }
          _expectCanonicalSuccessors(
            _state(
              Board(rows: 20, columns: 20, cells: cells),
              player: player,
              ply: player == Player.black ? 42 : 43,
            ),
            reason: 'density $density, ${player.name}',
          );
        }
      }
    },
  );

  test('handles finite boundaries, birth colors and survivor ownership', () {
    final board = boardWith({
      const Coordinate(0, 1): CellState.black,
      const Coordinate(1, 0): CellState.white,
      const Coordinate(1, 1): CellState.white,
      const Coordinate(0, 18): CellState.white,
      const Coordinate(1, 18): CellState.black,
      const Coordinate(1, 19): CellState.black,
      const Coordinate(18, 0): CellState.black,
      const Coordinate(18, 1): CellState.white,
      const Coordinate(19, 1): CellState.black,
      const Coordinate(18, 18): CellState.white,
      const Coordinate(18, 19): CellState.black,
      const Coordinate(19, 18): CellState.white,
      const Coordinate(9, 9): CellState.white,
      const Coordinate(8, 8): CellState.black,
      const Coordinate(8, 9): CellState.black,
      const Coordinate(8, 10): CellState.black,
    });
    for (final player in Player.values) {
      _expectCanonicalSuccessors(_state(board, player: player));
    }
  });

  test('matches canonical states along reachable game trajectories', () {
    final random = Random(1234);
    for (var game = 0; game < 3; game++) {
      var state = engine.initialState();
      for (var turn = 0; turn < 8 && state.isActive; turn++) {
        _expectCanonicalSuccessors(state, reason: 'game $game, turn $turn');
        final centralMoves = engine
            .legalMoves(state)
            .where(
              (move) =>
                  move.row >= 7 &&
                  move.row <= 12 &&
                  move.column >= 7 &&
                  move.column <= 12,
            )
            .toList();
        final legal = centralMoves.isEmpty
            ? engine.legalMoves(state)
            : centralMoves;
        final move = legal[random.nextInt(legal.length)];
        state = engine
            .applyMove(
              state,
              GameMove(
                player: state.toMove!,
                row: move.row,
                column: move.column,
                expectedRevision: state.revision,
              ),
            )
            .state;
      }
    }
  });

  test('uses canonical elimination and mutual-extinction outcomes', () {
    final isolated = _state(
      boardWith({
        const Coordinate(0, 0): CellState.black,
        const Coordinate(19, 19): CellState.white,
      }),
    );
    _expectCanonicalSuccessors(isolated);
    expect(
      engine.searchSuccessors(isolated).single.state.outcome!.reason,
      OutcomeReason.mutualExtinction,
    );

    final elimination = _state(
      boardWith({
        const Coordinate(0, 0): CellState.black,
        const Coordinate(10, 10): CellState.white,
        const Coordinate(10, 11): CellState.white,
        const Coordinate(11, 10): CellState.white,
        const Coordinate(11, 11): CellState.white,
      }),
    );
    _expectCanonicalSuccessors(elimination);
    final first = engine.searchSuccessors(elimination).first.state;
    expect(first.outcome!.winner, Player.white);
    expect(first.outcome!.reason, OutcomeReason.elimination);
    expect(first.toMove, isNull);
  });

  test('respects population targets and absolute turn-limit plies', () {
    final board = engine.initialState().board;
    for (final target in [3, 5]) {
      for (final player in Player.values) {
        _expectCanonicalSuccessors(
          _state(
            board,
            rules: GameRules.standard(victory: PopulationTargetVictory(target)),
            player: player,
          ),
        );
      }
    }
    final rules = GameRules.standard(victory: TurnLimitPopulationVictory(10));
    for (final ply in [0, 8, 9]) {
      final state = _state(
        board,
        rules: rules,
        ply: ply,
        player: ply.isEven ? Player.black : Player.white,
      );
      _expectCanonicalSuccessors(state);
      final first = engine.searchSuccessors(state).first.state;
      expect(first.ply, ply + 1);
      expect(first.revision, ply + 1);
      expect(first.isActive, ply < 9);
      if (ply == 9) {
        expect(first.outcome!.reason, OutcomeReason.turnLimitTie);
        expect(first.toMove, isNull);
      }
    }
  });

  test(
    'completed states and states without legal placements yield nothing',
    () {
      final fullBoard = Board(
        rows: 20,
        columns: 20,
        cells: List.generate(
          GameRules.cellCount,
          (index) => index.isEven ? CellState.black : CellState.white,
        ),
      );
      _expectCanonicalSuccessors(_state(fullBoard));
      final completed = GameState(
        rules: GameRules.standard(),
        board: fullBoard,
        ply: 1,
        revision: 1,
        toMove: null,
        outcome: engine.evaluateOutcome(
          fullBoard,
          GameRules.standard(),
          ply: 1,
        ),
      );
      expect(engine.searchSuccessors(completed), isEmpty);
    },
  );
}

GameState _state(
  Board board, {
  GameRules? rules,
  Player player = Player.black,
  int ply = 0,
}) => GameState(
  rules: rules ?? GameRules.standard(),
  board: board,
  ply: ply,
  revision: ply,
  toMove: player,
  outcome: null,
);

void _expectCanonicalSuccessors(GameState state, {String? reason}) {
  const engine = GameEngine();
  final expected = <GameState, GameMove>{};
  for (final coordinate in engine.legalMoves(state)) {
    final move = GameMove(
      player: state.toMove!,
      row: coordinate.row,
      column: coordinate.column,
      expectedRevision: state.revision,
    );
    final next = engine.applyMove(state, move).state;
    expected.putIfAbsent(next, () => move);
  }
  final actual = engine.searchSuccessors(state).toList();
  expect(
    actual.map((successor) => successor.state),
    expected.keys,
    reason: reason,
  );
  expect(
    actual.map((successor) => successor.move),
    expected.values,
    reason: reason,
  );
}
