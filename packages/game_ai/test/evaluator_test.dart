import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

void main() {
  const evaluator = HeuristicEvaluator();

  test('fixture has exact explainable features and score', () {
    var board = Board.empty(rows: GameRules.rows, columns: GameRules.columns);
    board = board.withCell(const Coordinate(4, 4), CellState.black);
    board = board.withCell(const Coordinate(4, 5), CellState.black);
    board = board.withCell(const Coordinate(5, 4), CellState.black);
    board = board.withCell(const Coordinate(10, 10), CellState.white);

    final black = evaluator.extractFeatures(board, Player.black);
    final white = evaluator.extractFeatures(board, Player.white);
    final state = GameState(
      rules: GameRules.standard(victory: TurnLimitPopulationVictory(100)),
      board: board,
      ply: 0,
      revision: 0,
      toMove: Player.black,
      outcome: null,
    );

    expect(black.populationAdvantage, 2);
    expect(black.resilientCellAdvantage, 3);
    expect(black.birthPotentialAdvantage, 1);
    expect(black.frontierControlAdvantage, 4);
    expect(black.friendlyAdjacencyAdvantage, 3);
    expect(evaluator.evaluate(state, Player.black).score, 286);
    expect(evaluator.evaluate(state, Player.white).score, -286);
    expect(black.populationAdvantage, -white.populationAdvantage);
    expect(black.resilientCellAdvantage, -white.resilientCellAdvantage);
    expect(black.birthPotentialAdvantage, -white.birthPotentialAdvantage);
    expect(black.frontierControlAdvantage, -white.frontierControlAdvantage);
    expect(black.friendlyAdjacencyAdvantage, -white.friendlyAdjacencyAdvantage);
  });

  test('terminal result overrides positional features', () {
    final rules = GameRules.standard();
    var board = Board.empty(rows: GameRules.rows, columns: GameRules.columns);
    board = board.withCell(const Coordinate(0, 0), CellState.black);
    final outcome = GameOutcome.win(
      winner: Player.black,
      reason: OutcomeReason.elimination,
      blackPopulation: 1,
      whitePopulation: 0,
    );
    final state = GameState(
      rules: rules,
      board: board,
      ply: 4,
      revision: 4,
      toMove: null,
      outcome: outcome,
    );

    expect(evaluator.evaluate(state, Player.black).score, 1000000);
    expect(evaluator.evaluate(state, Player.white).score, -1000000);
  });
}
