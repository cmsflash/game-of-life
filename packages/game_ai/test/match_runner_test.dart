import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

void main() {
  test('greedy-vs-greedy experiment is deterministic and bounded', () {
    const agent = GreedyAgent();
    const runner = AiMatchRunner(black: agent, white: agent);
    final rules = GameRules.standard(victory: TurnLimitPopulationVictory(2));

    final first = runner.play(rules: rules, safetyMaxPlies: 2);
    final second = runner.play(rules: rules, safetyMaxPlies: 2);

    expect(first.turns, hasLength(2));
    expect(first.truncated, isFalse);
    expect(first.finalState.outcome, isNotNull);
    expect(first.toJson(includeTurns: true), second.toJson(includeTurns: true));
  });

  test('safety bound reports truncation without inventing an outcome', () {
    const agent = GreedyAgent();
    const runner = AiMatchRunner(black: agent, white: agent);

    final result = runner.play(safetyMaxPlies: 2);

    expect(result.truncated, isTrue);
    expect(result.finalState.isActive, isTrue);
    expect(result.finalState.outcome, isNull);
  });

  test('custom nonzero-ply start records exact reproducibility metadata', () {
    const engine = GameEngine();
    const agent = GreedyAgent();
    const runner = AiMatchRunner(black: agent, white: agent);
    final rules = GameRules.standard(victory: TurnLimitPopulationVictory(4));
    var state = engine.initialState(rules);
    state = engine
        .applyMove(
          state,
          const GameMove(
            player: Player.black,
            row: 0,
            column: 0,
            expectedRevision: 0,
          ),
        )
        .state;
    state = engine
        .applyMove(
          state,
          const GameMove(
            player: Player.white,
            row: 0,
            column: 0,
            expectedRevision: 1,
          ),
        )
        .state;

    final result = runner.play(initialState: state, safetyMaxPlies: 4);
    final json = result.toJson();

    expect(result.initialState.ply, 2);
    expect(result.finalState.ply, 4);
    expect(result.safetyMaxPlies, 4);
    expect(result.truncated, isFalse);
    expect(json['initialStateHash'], state.stateHash);
    expect(json['initialPly'], 2);
    expect(json['finalPly'], 4);
    expect(json['plies'], 2);
    expect(json['safetyMaxPlies'], 4);
  });
}
