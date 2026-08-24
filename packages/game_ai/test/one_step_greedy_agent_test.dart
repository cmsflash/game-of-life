import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

void main() {
  const engine = GameEngine();

  test('strategy percentages map all bucket boundaries', () {
    const percentages = OneStepStrategyPercentages(
      maxSelfCells: 20,
      minOpponentCells: 30,
      maxCellAdvantage: 50,
    );

    expect(
      percentages.strategyForBucket(0),
      OneStepGreedyStrategy.maxSelfCells,
    );
    expect(
      percentages.strategyForBucket(19),
      OneStepGreedyStrategy.maxSelfCells,
    );
    expect(
      percentages.strategyForBucket(20),
      OneStepGreedyStrategy.minOpponentCells,
    );
    expect(
      percentages.strategyForBucket(49),
      OneStepGreedyStrategy.minOpponentCells,
    );
    expect(
      percentages.strategyForBucket(50),
      OneStepGreedyStrategy.maxCellAdvantage,
    );
    expect(
      percentages.strategyForBucket(99),
      OneStepGreedyStrategy.maxCellAdvantage,
    );
  });

  test('checked percentages reject totals other than 100', () {
    expect(
      () => OneStepStrategyPercentages.checked(
        maxSelfCells: 50,
        minOpponentCells: 25,
        maxCellAdvantage: 20,
      ),
      throwsArgumentError,
    );
  });

  for (final strategy in OneStepGreedyStrategy.values) {
    test('${strategy.name} selects the best one-step population result', () {
      final percentages = switch (strategy) {
        OneStepGreedyStrategy.maxSelfCells => const OneStepStrategyPercentages(
          maxSelfCells: 100,
          minOpponentCells: 0,
          maxCellAdvantage: 0,
        ),
        OneStepGreedyStrategy.minOpponentCells =>
          const OneStepStrategyPercentages(
            maxSelfCells: 0,
            minOpponentCells: 100,
            maxCellAdvantage: 0,
          ),
        OneStepGreedyStrategy.maxCellAdvantage =>
          const OneStepStrategyPercentages(
            maxSelfCells: 0,
            minOpponentCells: 0,
            maxCellAdvantage: 100,
          ),
      };
      final agent = OneStepGreedyAgent(percentages: percentages);
      final state = engine.initialState(
        GameRules.standard(victory: TurnLimitPopulationVictory(100)),
      );

      final candidates = agent.analyze(state);
      final decision = agent.chooseMove(state);
      final bestScore = candidates
          .map((candidate) => candidate.evaluation.scoreFor(strategy))
          .reduce((left, right) => left > right ? left : right);

      expect(decision.strategy, strategy);
      expect(decision.evaluation.scoreFor(strategy), bestScore);
      expect(engine.validateMove(state, decision.move).isValid, isTrue);
      expect(decision.legalMoveCount, 396);
      expect(decision.uniqueSuccessorCount, 25);
    });
  }

  test('the same state and mix always return the same decision', () {
    const agent = OneStepGreedyAgent(
      percentages: OneStepStrategyPercentages(
        maxSelfCells: 25,
        minOpponentCells: 25,
        maxCellAdvantage: 50,
      ),
    );
    final state = engine.initialState(
      GameRules.standard(victory: TurnLimitPopulationVictory(100)),
    );

    final first = agent.chooseMove(state);
    final second = agent.chooseMove(state);

    expect(first.toJson(), second.toJson());
    expect(
      first.strategy,
      agent.percentages.strategyForBucket(agent.strategyBucket(state)),
    );
  });
}
