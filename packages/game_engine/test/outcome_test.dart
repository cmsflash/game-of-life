import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  const engine = GameEngine();

  group('elimination outcomes', () {
    test('mutual extinction is a draw', () {
      final outcome = engine.evaluateOutcome(
        boardWith({}),
        GameRules.standard(),
        ply: 1,
      );

      expect(outcome!.type, OutcomeType.draw);
      expect(outcome.reason, OutcomeReason.mutualExtinction);
      expect(outcome.winner, isNull);
    });

    test('the sole surviving color wins', () {
      final blackOutcome = engine.evaluateOutcome(
        boardWith({const Coordinate(5, 5): CellState.black}),
        GameRules.standard(),
        ply: 1,
      );
      final whiteOutcome = engine.evaluateOutcome(
        boardWith({const Coordinate(5, 5): CellState.white}),
        GameRules.standard(),
        ply: 1,
      );

      expect(blackOutcome!.winner, Player.black);
      expect(blackOutcome.reason, OutcomeReason.elimination);
      expect(whiteOutcome!.winner, Player.white);
      expect(whiteOutcome.reason, OutcomeReason.elimination);
    });

    test('a suicidal move can award the opponent victory', () {
      final state = activeState(
        boardWith({
          const Coordinate(0, 0): CellState.black,
          const Coordinate(10, 9): CellState.white,
          const Coordinate(10, 10): CellState.white,
          const Coordinate(10, 11): CellState.white,
        }),
      );
      const move = GameMove(
        player: Player.black,
        row: 19,
        column: 19,
        expectedRevision: 0,
      );

      final result = engine.applyMove(state, move).state;

      expect(result.blackPopulation, 0);
      expect(result.whitePopulation, greaterThan(0));
      expect(result.outcome!.winner, Player.white);
      expect(result.outcome!.reason, OutcomeReason.elimination);
    });
  });

  group('population target', () {
    final rules = GameRules.standard(victory: PopulationTargetVictory(3));

    test('one color reaching the target wins', () {
      final outcome = engine.evaluateOutcome(
        boardWith({
          const Coordinate(1, 1): CellState.black,
          const Coordinate(1, 2): CellState.black,
          const Coordinate(2, 1): CellState.black,
          const Coordinate(10, 10): CellState.white,
        }),
        rules,
        ply: 1,
      );

      expect(outcome!.winner, Player.black);
      expect(outcome.reason, OutcomeReason.populationTarget);
    });

    test('simultaneously reaching the target is a draw', () {
      final outcome = engine.evaluateOutcome(
        boardWith({
          const Coordinate(1, 1): CellState.black,
          const Coordinate(1, 2): CellState.black,
          const Coordinate(2, 1): CellState.black,
          const Coordinate(10, 10): CellState.white,
          const Coordinate(10, 11): CellState.white,
          const Coordinate(11, 10): CellState.white,
        }),
        rules,
        ply: 1,
      );

      expect(outcome!.type, OutcomeType.draw);
      expect(outcome.reason, OutcomeReason.simultaneousTarget);
    });
  });

  group('turn-limit population', () {
    final rules = GameRules.standard(victory: TurnLimitPopulationVictory(2));

    test('does not score before the limit', () {
      final outcome = engine.evaluateOutcome(
        boardWith({
          const Coordinate(1, 1): CellState.black,
          const Coordinate(1, 2): CellState.black,
          const Coordinate(10, 10): CellState.white,
        }),
        rules,
        ply: 1,
      );

      expect(outcome, isNull);
    });

    test('higher population wins at the limit', () {
      final outcome = engine.evaluateOutcome(
        boardWith({
          const Coordinate(1, 1): CellState.black,
          const Coordinate(1, 2): CellState.black,
          const Coordinate(10, 10): CellState.white,
        }),
        rules,
        ply: 2,
      );

      expect(outcome!.winner, Player.black);
      expect(outcome.reason, OutcomeReason.turnLimitPopulation);
    });

    test('equal population is a draw at the limit', () {
      final outcome = engine.evaluateOutcome(
        boardWith({
          const Coordinate(1, 1): CellState.black,
          const Coordinate(10, 10): CellState.white,
        }),
        rules,
        ply: 2,
      );

      expect(outcome!.type, OutcomeType.draw);
      expect(outcome.reason, OutcomeReason.turnLimitTie);
    });

    test('elimination takes precedence on the limit ply', () {
      final outcome = engine.evaluateOutcome(
        boardWith({const Coordinate(1, 1): CellState.black}),
        rules,
        ply: 2,
      );

      expect(outcome!.winner, Player.black);
      expect(outcome.reason, OutcomeReason.elimination);
    });
  });

  test('a full non-eliminated board draws for no legal moves', () {
    final cells = List<CellState>.generate(
      GameRules.cellCount,
      (index) => index.isEven ? CellState.black : CellState.white,
    );
    final board = Board(rows: 20, columns: 20, cells: cells);

    final outcome = engine.evaluateOutcome(board, GameRules.standard(), ply: 1);

    expect(outcome!.type, OutcomeType.draw);
    expect(outcome.reason, OutcomeReason.noLegalMoves);
  });

  group('rule validation', () {
    test('requires an even positive turn limit', () {
      expect(() => TurnLimitPopulationVictory(0), throwsArgumentError);
      expect(() => TurnLimitPopulationVictory(3), throwsArgumentError);
    });

    test('requires target above initial count and within the board', () {
      expect(() => PopulationTargetVictory(2), throwsArgumentError);
      expect(() => PopulationTargetVictory(401), throwsArgumentError);
    });
  });
}
