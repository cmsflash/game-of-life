import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

void main() {
  const engine = GameEngine();

  test('initial 396 legal moves collapse to 25 exact successors', () {
    const agent = GreedyAgent();
    final state = engine.initialState(
      GameRules.standard(victory: TurnLimitPopulationVictory(100)),
    );

    final candidates = agent.analyze(state);

    expect(engine.legalMoves(state), hasLength(396));
    expect(candidates, hasLength(25));
    expect(
      candidates.fold<int>(
        0,
        (total, candidate) => total + candidate.equivalentMoveCount,
      ),
      396,
    );
    expect(
      candidates.map((candidate) => candidate.turn.state).toSet(),
      hasLength(25),
    );
  });

  test('zero-weight ties choose the row-major first representative', () {
    const agent = GreedyAgent(
      evaluator: HeuristicEvaluator(
        weights: EvaluationWeights(
          population: 0,
          resilientCells: 0,
          birthPotential: 0,
          frontierControl: 0,
          friendlyAdjacency: 0,
        ),
      ),
    );
    final state = engine.initialState(
      GameRules.standard(victory: TurnLimitPopulationVictory(100)),
    );

    final first = agent.chooseMove(state);
    final second = agent.chooseMove(state);

    expect(first.move.coordinate, const Coordinate(0, 0));
    expect(second.move, first.move);
    expect(first.legalMoveCount, 396);
    expect(first.uniqueSuccessorCount, 25);
  });

  test('chosen transition is exactly the engine transition', () {
    const agent = GreedyAgent();
    final state = engine.initialState(
      GameRules.standard(victory: TurnLimitPopulationVictory(100)),
    );

    final decision = agent.chooseMove(state);
    final authoritative = engine.applyMove(state, decision.move);

    expect(decision.turn.state, authoritative.state);
    expect(decision.evaluation.score, greaterThan(-1000000));
  });

  test('selects a valid White move from a non-initial ply', () {
    const agent = GreedyAgent();
    final initial = engine.initialState(
      GameRules.standard(victory: TurnLimitPopulationVictory(100)),
    );
    final afterBlack = engine
        .applyMove(
          initial,
          const GameMove(
            player: Player.black,
            row: 0,
            column: 0,
            expectedRevision: 0,
          ),
        )
        .state;

    final decision = agent.chooseMove(afterBlack);

    expect(afterBlack.toMove, Player.white);
    expect(decision.move.player, Player.white);
    expect(decision.move.expectedRevision, 1);
    expect(engine.validateMove(afterBlack, decision.move).isValid, isTrue);
    expect(decision.turn.state.ply, 2);
  });

  test('an immediate terminal win outranks positional features', () {
    const agent = GreedyAgent();
    var board = Board.empty(rows: GameRules.rows, columns: GameRules.columns);
    board = board.withCell(const Coordinate(9, 9), CellState.black);
    board = board.withCell(const Coordinate(9, 10), CellState.black);
    board = board.withCell(const Coordinate(10, 9), CellState.black);
    board = board.withCell(const Coordinate(10, 10), CellState.white);
    final state = GameState(
      rules: GameRules.standard(victory: TurnLimitPopulationVictory(100)),
      board: board,
      ply: 0,
      revision: 0,
      toMove: Player.black,
      outcome: null,
    );

    final candidates = agent.analyze(state);
    final decision = agent.chooseMove(state);

    expect(
      candidates.any((candidate) => candidate.turn.state.isActive),
      isTrue,
    );
    expect(decision.evaluation.score, 1000000);
    expect(decision.turn.state.outcome?.winner, Player.black);
    expect(decision.turn.state.outcome?.reason, OutcomeReason.elimination);
  });
}
