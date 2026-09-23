import 'package:game_ai/experimental_search.dart';
import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

const _engine = GameEngine();

void main() {
  test('validates strict-budget configuration and terminal input', () {
    final state = _engine.initialState();
    for (final agent in [
      const BudgetedSearchAgent(maxDepth: 0, transitionBudget: 400),
      const BudgetedSearchAgent(maxDepth: 65, transitionBudget: 400),
      const BudgetedSearchAgent(maxDepth: 2, transitionBudget: 399),
      const BudgetedSearchAgent(
        maxDepth: 2,
        transitionBudget: 400,
        fullWidthDepth: 0,
      ),
      const BudgetedSearchAgent(
        maxDepth: 2,
        transitionBudget: 400,
        beamWidth: 0,
      ),
      const BudgetedSearchAgent(
        maxDepth: 2,
        transitionBudget: 400,
        tieBreakSeed: -1,
      ),
    ]) {
      expect(() => agent.chooseMove(state), throwsArgumentError);
    }
    final terminal = _engine.searchSuccessors(_winningState()).first.state;
    expect(terminal.isActive, isFalse);
    expect(
      () => const BudgetedSearchAgent(
        maxDepth: 2,
        transitionBudget: 400,
      ).chooseMove(terminal),
      throwsStateError,
    );
  });

  test('all generated candidates and repeated iterations consume budget', () {
    final state = _engine.initialState();
    final roots = _engine.searchSuccessors(state).toList();
    final expectedDepthTwoCost =
        roots.length * 2 +
        roots
            .where((child) => child.state.isActive)
            .fold<int>(
              0,
              (sum, child) =>
                  sum + _engine.searchSuccessors(child.state).length,
            );
    final exact = const BudgetedSearchAgent(
      maxDepth: 2,
      transitionBudget: 100000,
    ).chooseMove(state);
    final beam = const BudgetedSearchAgent(
      maxDepth: 2,
      transitionBudget: 100000,
      fullWidthDepth: 1,
      beamWidth: 1,
    ).chooseMove(state);
    expect(exact.completedDepth, 2);
    expect(exact.cacheHits, 0);
    expect(exact.cutoffs, greaterThan(0));
    expect(exact.successorEvaluations, expectedDepthTwoCost);
    // Even a width-one beam generates and charges every candidate to rank it.
    expect(beam.successorEvaluations, expectedDepthTwoCost);
    expect(beam.nodesVisited, lessThan(exact.nodesVisited));
    expect(exact.successorEvaluations, greaterThan(exact.nodesVisited));
  });

  test('strict total cap cannot be bypassed by minimum depth or lookahead', () {
    final state = _engine.initialState();
    for (final budget in [400, 401, 1000, 3000]) {
      for (final width in [1, 8, 400]) {
        final decision = BudgetedSearchAgent(
          maxDepth: 12,
          transitionBudget: budget,
          fullWidthDepth: 1,
          beamWidth: width,
        ).chooseMove(state);
        expect(decision.successorEvaluations, lessThanOrEqualTo(budget));
        expect(decision.completedDepth, greaterThanOrEqualTo(1));
        expect(decision.maxVisitedPly, greaterThanOrEqualTo(1));
        expect(
          decision.maxVisitedPly,
          lessThanOrEqualTo(decision.attemptedDepth),
        );
        expect(
          decision.maxVisitedPly,
          lessThanOrEqualTo(decision.agent.maxDepth),
        );
        expect(decision.budgetExhausted, isTrue);
        expect(decision.successorEvaluations, budget);
        expect(_engine.validateMove(state, decision.move).isValid, isTrue);
      }
    }
  });

  test('partial deeper work preserves the last fully completed iteration', () {
    final state = _engine.initialState();
    final baseline = const BudgetedSearchAgent(
      maxDepth: 2,
      transitionBudget: 100000,
      tieBreakSeed: 17,
    ).chooseMove(state);
    final interrupted = BudgetedSearchAgent(
      maxDepth: 5,
      transitionBudget: baseline.successorEvaluations + 1,
      tieBreakSeed: 17,
    ).chooseMove(state);
    expect(interrupted.completedDepth, 2);
    expect(interrupted.attemptedDepth, 3);
    expect(interrupted.budgetExhausted, isTrue);
    expect(interrupted.successorEvaluations, baseline.successorEvaluations + 1);
    expect(interrupted.move, baseline.move);
    expect(interrupted.score, baseline.score);
    expect(interrupted.maxVisitedPly, 2);

    final minimal = const BudgetedSearchAgent(
      maxDepth: 5,
      transitionBudget: 400,
    ).chooseMove(state);
    expect(minimal.completedDepth, 1);
  });

  test('visited reach includes nodes from an aborted deeper iteration', () {
    final actual = const BudgetedSearchAgent(
      maxDepth: 5,
      transitionBudget: 3000,
    ).chooseMove(_engine.initialState());
    expect(actual.completedDepth, 2);
    expect(actual.attemptedDepth, 3);
    expect(actual.maxVisitedPly, 3);
    expect(actual.budgetExhausted, isTrue);
    expect(actual.toJson(), containsPair('maxVisitedPly', 3));
  });

  test('complete full-width depth three agrees with unpruned minimax', () {
    for (final player in Player.values) {
      final state = _tacticalState(player);
      final expected = _oracleRoot(state, depth: 3);
      final actual = const BudgetedSearchAgent(
        maxDepth: 3,
        transitionBudget: 1000000,
      ).chooseMove(state);
      expect(actual.completedDepth, 3);
      expect(actual.maxVisitedPly, 3);
      expect(actual.score, expected.score);
      expect(actual.move, expected.moves.first);
      expect(actual.budgetExhausted, isFalse);
    }
  });

  test('selective depth semantics agree with an unpruned beam oracle', () {
    for (final player in Player.values) {
      final state = _tacticalState(player);
      for (final fullWidthDepth in [1, 2]) {
        final expected = _oracleRoot(
          state,
          depth: 3,
          fullWidthDepth: fullWidthDepth,
          beamWidth: 2,
        );
        final actual = BudgetedSearchAgent(
          maxDepth: 3,
          transitionBudget: 1000000,
          fullWidthDepth: fullWidthDepth,
          beamWidth: 2,
          tieBreakSeed: 7,
        ).chooseMove(state);
        expect(actual.completedDepth, 3);
        expect(actual.score, expected.score);
        expect(expected.moves, contains(actual.move));
      }
    }
  });

  test('beam widths at least 400 are identical to full-width search', () {
    final state = _engine.initialState();
    final exact = const BudgetedSearchAgent(
      maxDepth: 4,
      transitionBudget: 1000000,
      tieBreakSeed: 11,
    ).chooseMove(state);
    for (final width in [400, 500]) {
      final wide = BudgetedSearchAgent(
        maxDepth: 4,
        transitionBudget: 1000000,
        fullWidthDepth: 1,
        beamWidth: width,
        tieBreakSeed: 11,
      ).chooseMove(state);
      expect(wide.completedDepth, 4);
      expect(wide.score, exact.score);
      expect(wide.move, exact.move);
      expect(wide.successorEvaluations, exact.successorEvaluations);
      expect(wide.nodesVisited, exact.nodesVisited);
      expect(wide.cacheHits, exact.cacheHits);
      expect(wide.cacheHits, greaterThan(0));
    }
  });

  test(
    'selective terminal scores do not terminate iterative deepening early',
    () {
      final actual = const BudgetedSearchAgent(
        maxDepth: 4,
        transitionBudget: 400,
        fullWidthDepth: 1,
        beamWidth: 1,
      ).chooseMove(_winningState());
      expect(actual.score, terminalScore);
      expect(actual.completedDepth, 4);
      expect(actual.attemptedDepth, 4);
      expect(actual.maxVisitedPly, 1);
      expect(actual.toJson(), containsPair('maxVisitedPly', 1));
    },
  );

  test('turn-limit scoring and seeded budgeted decisions are reproducible', () {
    final base = _tacticalState(Player.black);
    final state = GameState(
      rules: GameRules.standard(victory: TurnLimitPopulationVictory(24)),
      board: base.board,
      ply: 22,
      revision: 22,
      toMove: Player.black,
      outcome: null,
    );
    final expected = _oracleRoot(state, depth: 3);
    const agent = BudgetedSearchAgent(
      maxDepth: 3,
      transitionBudget: 1000000,
      tieBreakSeed: 99,
      name: 'reproducibility-test',
    );
    final first = agent.chooseMove(state);
    final second = agent.chooseMove(state);
    expect(first.score, expected.score);
    expect(expected.moves, contains(first.move));
    expect(
      first.toJson()..remove('elapsedMicroseconds'),
      second.toJson()..remove('elapsedMicroseconds'),
    );
    expect(first.toJson(), containsPair('transitionBudget', 1000000));
    expect(first.toJson(), containsPair('fullWidthDepth', 64));
    expect(first.toJson(), containsPair('beamWidth', 8));
    expect(first.toJson(), containsPair('maxDepth', 3));
    expect(first.toJson(), containsPair('name', 'reproducibility-test'));
    expect(first.elapsedMicroseconds, first.elapsed.inMicroseconds);
  });
}

GameState _tacticalState(Player player) => _state({
  const Coordinate(5, 5): CellState.black,
  const Coordinate(5, 6): CellState.black,
  const Coordinate(6, 5): CellState.white,
  const Coordinate(6, 6): CellState.black,
  const Coordinate(8, 7): CellState.white,
  const Coordinate(8, 8): CellState.white,
  const Coordinate(8, 9): CellState.black,
}, player: player);

GameState _winningState() => _state({
  const Coordinate(5, 5): CellState.black,
  const Coordinate(5, 6): CellState.black,
  const Coordinate(6, 5): CellState.black,
  const Coordinate(6, 6): CellState.black,
  const Coordinate(19, 19): CellState.white,
});

GameState _state(
  Map<Coordinate, CellState> pieces, {
  Player player = Player.black,
}) {
  final cells = List<CellState>.filled(GameRules.cellCount, CellState.empty);
  for (final piece in pieces.entries) {
    cells[piece.key.indexFor(GameRules.columns)] = piece.value;
  }
  final ply = player == Player.black ? 22 : 23;
  return GameState(
    rules: GameRules.standard(),
    board: Board(rows: 20, columns: 20, cells: cells),
    ply: ply,
    revision: ply,
    toMove: player,
    outcome: null,
  );
}

({int score, List<GameMove> moves}) _oracleRoot(
  GameState state, {
  required int depth,
  int fullWidthDepth = 64,
  int beamWidth = 8,
}) {
  var best = -terminalScore - 1;
  final moves = <GameMove>[];
  for (final successor in _engine.searchSuccessors(state)) {
    final value = _oracle(
      successor.state,
      depth - 1,
      state.toMove!,
      1,
      fullWidthDepth,
      beamWidth,
    );
    if (value > best) {
      best = value;
      moves
        ..clear()
        ..add(successor.move);
    } else if (value == best) {
      moves.add(successor.move);
    }
  }
  return (score: best, moves: moves);
}

// Unpruned and uncached: independently evaluate every retained child.
int _oracle(
  GameState state,
  int depth,
  Player player,
  int plyFromRoot,
  int fullWidthDepth,
  int beamWidth,
) {
  if (!state.isActive || depth == 0) return evaluatePosition(state, player);
  final maximizing = state.toMove == player;
  var children = _engine.searchSuccessors(state).toList();
  if (plyFromRoot >= fullWidthDepth) {
    children.sort((a, b) {
      final left = evaluatePosition(a.state, player);
      final right = evaluatePosition(b.state, player);
      final comparison = maximizing
          ? right.compareTo(left)
          : left.compareTo(right);
      return comparison != 0
          ? comparison
          : a.move.coordinate.compareTo(b.move.coordinate);
    });
    children = children.take(beamWidth).toList();
  }
  var best = maximizing ? -terminalScore - 1 : terminalScore + 1;
  for (final child in children) {
    final value = _oracle(
      child.state,
      depth - 1,
      player,
      plyFromRoot + 1,
      fullWidthDepth,
      beamWidth,
    );
    if ((maximizing && value > best) || (!maximizing && value < best)) {
      best = value;
    }
  }
  return best;
}
