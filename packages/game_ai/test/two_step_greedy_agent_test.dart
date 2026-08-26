import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

void main() {
  const engine = GameEngine();

  test('chooses the largest worst-case two-ply cell advantage', () {
    final state = engine.initialState(
      GameRules.standard(victory: TurnLimitPopulationVictory(100)),
    );
    const agent = TwoStepMaxDifferenceAgent();

    final candidates = agent.analyze(state);
    final decision = agent.chooseMove(state);
    final bestScore = candidates
        .map((candidate) => candidate.worstCaseCellAdvantage)
        .reduce((left, right) => left > right ? left : right);

    expect(decision.worstCaseCellAdvantage, bestScore);
    expect(decision.worstReply, isNotNull);
    expect(decision.opponentLegalMoveCount, greaterThan(0));
    expect(decision.opponentUniqueSuccessorCount, greaterThan(0));
    expect(engine.validateMove(state, decision.move).isValid, isTrue);
  });

  test('scores a terminal first move without an opponent reply', () {
    final state = engine.initialState(
      GameRules.standard(victory: TurnLimitPopulationVictory(1 + 1)),
    );
    final black = const OneStepGreedyAgent(
      percentages: OneStepStrategyPercentages(
        maxSelfCells: 0,
        minOpponentCells: 0,
        maxCellAdvantage: 100,
      ),
    ).chooseMove(state);
    final afterBlack = engine.applyMove(state, black.move).state;
    const agent = TwoStepMaxDifferenceAgent();

    final decision = agent.chooseMove(afterBlack);

    expect(decision.turn.state.isActive, isFalse);
    expect(decision.worstReply, isNull);
    expect(decision.opponentLegalMoveCount, 0);
    expect(decision.worstCaseCellAdvantage, decision.immediateCellAdvantage);
  });

  test('seeded tie-breaking is reproducible', () {
    final state = engine.initialState(
      GameRules.standard(victory: TurnLimitPopulationVictory(100)),
    );
    const agent = TwoStepMaxDifferenceAgent(tieBreakSeed: 7);

    final first = agent.chooseMove(state);
    final second = agent.chooseMove(state);

    expect(first.toJson(), second.toJson());
    expect(first.tieBreakSeed, 7);
  });

  test('completed games cannot be analyzed', () {
    final state = engine.initialState(
      GameRules.standard(victory: TurnLimitPopulationVictory(2)),
    );
    const oneStep = OneStepGreedyAgent();
    final black = engine.applyMove(state, oneStep.chooseMove(state).move).state;
    final completed = engine
        .applyMove(black, oneStep.chooseMove(black).move)
        .state;
    const agent = TwoStepMaxDifferenceAgent();

    expect(() => agent.analyze(completed), throwsStateError);
    expect(() => agent.chooseMove(completed), throwsStateError);
  });
}
