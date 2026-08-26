import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

void main() {
  const engine = GameEngine();

  test('chooses the largest one-ply population difference', () {
    const agent = OneStepMaxDifferenceAgent();
    final state = engine.initialState(
      GameRules.standard(victory: TurnLimitPopulationVictory(100)),
    );

    final candidates = agent.analyze(state);
    final decision = agent.chooseMove(state);
    final bestScore = candidates
        .map((candidate) => candidate.evaluation.cellAdvantage)
        .reduce((left, right) => left > right ? left : right);

    expect(decision.evaluation.cellAdvantage, bestScore);
    expect(engine.validateMove(state, decision.move).isValid, isTrue);
    expect(decision.legalMoveCount, 396);
    expect(decision.uniqueSuccessorCount, 25);
    expect(decision.toJson()['searchPlies'], 1);
  });

  test('seeded tie-breaking is reproducible and varies equal best moves', () {
    final state = engine.initialState(
      GameRules.standard(victory: TurnLimitPopulationVictory(100)),
    );
    final moves = <Coordinate>{};
    for (var seed = 0; seed < 20; seed++) {
      final agent = OneStepMaxDifferenceAgent(tieBreakSeed: seed);
      final first = agent.chooseMove(state);
      final second = agent.chooseMove(state);

      expect(first.move, second.move);
      expect(first.tieBreakSeed, seed);
      expect(first.tiedBestSuccessorCount, greaterThan(1));
      moves.add(first.move.coordinate);
    }

    expect(moves.length, greaterThan(1));
  });

  test('completed games cannot be analyzed', () {
    final state = engine.initialState(
      GameRules.standard(victory: TurnLimitPopulationVictory(2)),
    );
    const agent = OneStepMaxDifferenceAgent();
    final black = engine.applyMove(state, agent.chooseMove(state).move).state;
    final completed = engine
        .applyMove(black, agent.chooseMove(black).move)
        .state;

    expect(() => agent.analyze(completed), throwsStateError);
    expect(() => agent.chooseMove(completed), throwsStateError);
  });
}
