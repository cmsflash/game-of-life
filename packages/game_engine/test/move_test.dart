import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  const engine = GameEngine();

  GameMove move(
    GameState state,
    int row,
    int column, {
    Player? player,
    int? revision,
  }) => GameMove(
    player: player ?? state.toMove!,
    row: row,
    column: column,
    expectedRevision: revision ?? state.revision,
  );

  group('placement and evolution', () {
    test('an isolated placement dies but consumes the turn', () {
      final initial = engine.initialState();

      final turn = engine.applyMove(initial, move(initial, 0, 0));

      expect(turn.state.board, initial.board);
      expect(turn.state.ply, 1);
      expect(turn.state.revision, 1);
      expect(turn.state.toMove, Player.white);
      expect(turn.delta.placement.coordinate, const Coordinate(0, 0));
      expect(turn.delta.placement.player, Player.black);
      expect(
        turn.delta.evolution.deaths.map((death) => death.coordinate),
        contains(const Coordinate(0, 0)),
      );
    });

    test('two isolated moves repeat position but not state hash', () {
      final initial = engine.initialState();
      final first = engine.applyMove(initial, move(initial, 0, 0)).state;
      final second = engine.applyMove(first, move(first, 0, 0)).state;

      expect(second.board, initial.board);
      expect(second.toMove, initial.toMove);
      expect(second.positionHash, initial.positionHash);
      expect(second.stateHash, isNot(initial.stateHash));
      expect(second.ply, 2);
    });

    test('placement participates in every mover/majority combination', () {
      final cases = [
        (Player.black, CellState.black, CellState.black, CellState.black),
        (Player.black, CellState.black, CellState.white, CellState.black),
        (Player.black, CellState.white, CellState.white, CellState.white),
        (Player.white, CellState.black, CellState.black, CellState.black),
        (Player.white, CellState.black, CellState.white, CellState.white),
        (Player.white, CellState.white, CellState.white, CellState.white),
      ];

      for (final (mover, first, second, expectedBirth) in cases) {
        final state = activeState(
          boardWith({
            const Coordinate(4, 4): first,
            const Coordinate(4, 5): second,
          }),
          toMove: mover,
          ply: mover == Player.black ? 0 : 1,
        );

        final result = engine.applyMove(state, move(state, 5, 4));

        expect(result.delta.placement.player, mover);
        expect(result.state.board.at(5, 4), mover.cell);
        expect(result.state.board.at(5, 5), expectedBirth);
        expect(result.delta.evolution.births, hasLength(1));
        final birth = result.delta.evolution.births.single;
        expect(
          birth.coordinate,
          const Coordinate(5, 5),
          reason: 'mover=$mover, existing=$first/$second',
        );
        expect(birth.player, playerForCell(expectedBirth));
        expect(result.delta.evolution.deaths, isEmpty);
      }
    });

    test('placement is counted before evolution and can suppress a birth', () {
      final state = activeState(
        boardWith({
          const Coordinate(4, 4): CellState.black,
          const Coordinate(4, 5): CellState.black,
          const Coordinate(4, 6): CellState.white,
        }),
      );

      final result = engine.applyMove(state, move(state, 5, 4));

      expect(result.state.board.at(5, 5), CellState.empty);
      expect(
        result.delta.evolution.births.map((birth) => birth.coordinate),
        isNot(contains(const Coordinate(5, 5))),
      );
    });

    test('golden center-adjacent move has the specified result', () {
      final initial = engine.initialState();

      final result = engine.applyMove(initial, move(initial, 8, 9)).state;

      expect(coordinatesOf(result.board, CellState.black), {
        const Coordinate(8, 9),
        const Coordinate(8, 10),
        const Coordinate(9, 8),
        const Coordinate(10, 10),
      });
      expect(coordinatesOf(result.board, CellState.white), {
        const Coordinate(10, 9),
      });
    });

    test('does not mutate the prior board', () {
      final initial = engine.initialState();
      final before = initial.toJson();

      engine.applyMove(initial, move(initial, 8, 9));

      expect(initial.toJson(), before);
    });
  });

  group('move validation', () {
    test('rejects occupied coordinates', () {
      final state = engine.initialState();
      final validation = engine.validateMove(state, move(state, 9, 9));

      expect(validation.isValid, isFalse);
      expect(validation.code, MoveErrorCode.occupied);
      expect(
        () => engine.applyMove(state, move(state, 9, 9)),
        throwsA(
          isA<GameRuleViolation>().having(
            (error) => error.code,
            'code',
            MoveErrorCode.occupied,
          ),
        ),
      );
    });

    test('rejects every out-of-bounds direction', () {
      final state = engine.initialState();
      for (final coordinate in const [
        Coordinate(-1, 0),
        Coordinate(0, -1),
        Coordinate(20, 0),
        Coordinate(0, 20),
      ]) {
        expect(
          engine
              .validateMove(
                state,
                move(state, coordinate.row, coordinate.column),
              )
              .code,
          MoveErrorCode.outOfBounds,
        );
      }
    });

    test('rejects wrong player and stale revision', () {
      final state = engine.initialState();

      expect(
        engine
            .validateMove(state, move(state, 0, 0, player: Player.white))
            .code,
        MoveErrorCode.wrongPlayer,
      );
      expect(
        engine.validateMove(state, move(state, 0, 0, revision: 99)).code,
        MoveErrorCode.staleRevision,
      );
    });

    test('rejects moves after completion', () {
      final empty = boardWith({});
      final outcome = engine.evaluateOutcome(
        empty,
        GameRules.standard(),
        ply: 1,
      )!;
      final terminal = GameState(
        rules: GameRules.standard(),
        board: empty,
        ply: 1,
        revision: 1,
        toMove: null,
        outcome: outcome,
      );
      const attempted = GameMove(
        player: Player.black,
        row: 0,
        column: 0,
        expectedRevision: 1,
      );

      expect(
        engine.validateMove(terminal, attempted).code,
        MoveErrorCode.gameOver,
      );
      expect(engine.legalMoves(terminal), isEmpty);
    });

    test('tryApplyMove returns a typed rejection', () {
      final state = engine.initialState();
      final result = engine.tryApplyMove(state, move(state, 9, 9));

      expect(result, isA<RejectedMove>());
      expect((result as RejectedMove).validation.code, MoveErrorCode.occupied);
    });

    test('legal moves are exactly empty cells in row-major order', () {
      final state = engine.initialState();
      final legal = engine.legalMoves(state);

      expect(legal, hasLength(396));
      expect(legal.first, const Coordinate(0, 0));
      expect(legal.last, const Coordinate(19, 19));
      expect(legal, isNot(contains(const Coordinate(9, 9))));
    });
  });
}
