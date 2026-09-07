import 'dart:async';

import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

void main() {
  const engine = GameEngine();
  const ampleTime = Duration(hours: 1);

  test('validates configuration and rejects completed states', () {
    final state = engine.initialState();
    for (final agent in [
      const IterativeDeepeningAgent(minDepth: 0),
      const IterativeDeepeningAgent(minDepth: 4, maxDepth: 3),
      const IterativeDeepeningAgent(maxDepth: 65),
      const IterativeDeepeningAgent(maxNodes: 0),
      const IterativeDeepeningAgent(tieBreakSeed: -1),
      const IterativeDeepeningAgent(timeBudget: Duration(seconds: -1)),
    ]) {
      expect(() => agent.chooseMove(state), throwsArgumentError);
    }
    final terminal = GameState(
      rules: state.rules,
      board: Board.empty(rows: 20, columns: 20),
      ply: 0,
      revision: 0,
      toMove: null,
      outcome: GameOutcome.draw(
        reason: OutcomeReason.mutualExtinction,
        blackPopulation: 0,
        whitePopulation: 0,
      ),
    );
    expect(
      () => const IterativeDeepeningAgent().chooseMove(terminal),
      throwsStateError,
    );
  });

  test('depth one and two agree with independent existing agents', () {
    var state = engine.initialState();
    for (var ply = 0; ply < 4 && state.isActive; ply++) {
      final one = const OneStepMaxDifferenceAgent().chooseMove(state);
      final two = const TwoStepMaxDifferenceAgent().chooseMove(state);
      final depthOne = const IterativeDeepeningAgent(
        minDepth: 1,
        maxDepth: 1,
        timeBudget: ampleTime,
      ).chooseMove(state);
      final depthTwo = const IterativeDeepeningAgent(
        minDepth: 2,
        maxDepth: 2,
        timeBudget: ampleTime,
      ).chooseMove(state);
      expect(depthOne.score, one.evaluation.score);
      expect(depthOne.move, one.move);
      expect(depthTwo.score, two.worstCaseScore);
      expect(depthTwo.move, two.move);
      state = engine.applyMove(state, two.move).state;
    }
  });

  test('zero time still completes the three-ply launch baseline', () {
    final state = engine.initialState();
    final decision = const IterativeDeepeningAgent(
      timeBudget: Duration.zero,
    ).chooseMove(state);
    expect(decision.completedDepth, 3);
    expect(decision.attemptedDepth, 3);
    expect(decision.budgetExhausted, isTrue);
    expect(decision.turn.state, engine.applyMove(state, decision.move).state);
    expect(decision.toJson()['completedDepth'], 3);
    expect(decision.cutoffs, greaterThan(0));
  });

  test('completed depth three matches unpruned minimax', () {
    final state = engine.initialState();
    final expected = _oracle(state, 3, state.toMove!);
    final actual = const IterativeDeepeningAgent(
      maxDepth: 3,
      timeBudget: ampleTime,
    ).chooseMove(state);
    expect(actual.score, expected);
    expect(_oracle(actual.turn.state, 2, state.toMove!), expected);
  });

  test('can complete four or more plies without promotion to level 3', () {
    final state = engine.initialState();
    const agent = IterativeDeepeningAgent(
      minDepth: 4,
      maxDepth: 4,
      timeBudget: ampleTime,
    );
    final decision = agent.chooseMove(state);
    expect(agent.name, 'ai-level-2.9');
    expect(decision.completedDepth, 4);
    expect(decision.attemptedDepth, 4);
    expect(decision.budgetExhausted, isFalse);
    expect(decision.cacheHits, greaterThan(0));
  });

  test(
    'interrupted deeper iteration keeps the complete depth-three result',
    () {
      final state = engine.initialState();
      const baseline = IterativeDeepeningAgent(
        maxDepth: 3,
        timeBudget: ampleTime,
        tieBreakSeed: 17,
      );
      final complete = baseline.chooseMove(state);
      final interrupted = IterativeDeepeningAgent(
        maxDepth: 5,
        timeBudget: ampleTime,
        maxNodes: complete.nodesVisited + 1,
        tieBreakSeed: 17,
      ).chooseMove(state);
      expect(interrupted.completedDepth, 3);
      expect(interrupted.attemptedDepth, 4);
      expect(interrupted.budgetExhausted, isTrue);
      expect(interrupted.move, complete.move);
      expect(interrupted.score, complete.score);
    },
  );

  test(
    'async search yields and returns the same fixed-depth decision',
    () async {
      final state = engine.initialState();
      const agent = IterativeDeepeningAgent(
        maxDepth: 3,
        timeBudget: ampleTime,
        tieBreakSeed: 3,
      );
      final expected = agent.chooseMove(state);
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      try {
        final actual = await agent.chooseMoveAsync(state);
        expect(actual.move, expected.move);
        expect(actual.score, expected.score);
        expect(actual.nodesVisited, expected.nodesVisited);
        expect(ticks, greaterThan(1));
      } finally {
        timer.cancel();
      }
    },
  );

  test('cancellation interrupts even the minimum-depth search', () async {
    var cancelled = false;
    final timer = Timer(
      const Duration(milliseconds: 2),
      () => cancelled = true,
    );
    try {
      await expectLater(
        const IterativeDeepeningAgent().chooseMoveAsync(
          engine.initialState(),
          isCancelled: () => cancelled,
        ),
        throwsA(isA<SearchCancelledException>()),
      );
    } finally {
      timer.cancel();
    }
    await expectLater(
      const IterativeDeepeningAgent().chooseMoveAsync(
        engine.initialState(),
        isCancelled: () => true,
      ),
      throwsA(isA<SearchCancelledException>()),
    );
  });

  test('turn-limit adjudication is included in depth-three searches', () {
    for (final limit in [2, 4]) {
      final state = engine.initialState(
        GameRules.standard(victory: TurnLimitPopulationVictory(limit)),
      );
      final actual = const IterativeDeepeningAgent(
        maxDepth: 3,
        timeBudget: ampleTime,
      ).chooseMove(state);
      expect(actual.score, _oracle(state, 3, state.toMove!));
    }
  });
}

int _oracle(GameState state, int depth, Player player) {
  if (!state.isActive || depth == 0) return evaluatePosition(state, player);
  final values = const GameEngine()
      .searchSuccessors(state)
      .map((child) => _oracle(child.state, depth - 1, player));
  return values.reduce(
    state.toMove == player ? (a, b) => a > b ? a : b : (a, b) => a < b ? a : b,
  );
}
