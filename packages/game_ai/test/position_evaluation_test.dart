import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

void main() {
  const engine = GameEngine();

  test('unfinished positions retain the raw difference from either side', () {
    final state = _populationState(black: 398, white: 1);

    expect(state.isActive, isTrue);
    expect(evaluatePosition(state, Player.black), 397);
    expect(evaluatePosition(state, Player.white), -397);
    expect(terminalScore, greaterThan(GameRules.cellCount));
  });

  for (final player in Player.values) {
    for (final victory in <VictoryRule>[
      const EliminationVictory(),
      TurnLimitPopulationVictory(2),
      PopulationTargetVictory(3),
    ]) {
      test('${victory.mode} win/loss scoring from ${player.name}', () {
        final losingCells = victory is EliminationVictory ? 0 : 2;
        final state = _populationState(
          black: player == Player.black ? 3 : losingCells,
          white: player == Player.white ? 3 : losingCells,
          victory: victory,
          ply: 2,
        );

        expect(state.outcome!.winner, player);
        expect(evaluatePosition(state, player), terminalScore);
        expect(evaluatePosition(state, player.opponent), -terminalScore);
      });
    }

    test(
      'L1 takes a win over a larger unfinished advantage (${player.name})',
      () {
        final state = _winPreferenceState(player);
        const agent = OneStepMaxDifferenceAgent();
        final candidates = agent.analyze(state);
        final bestActiveDifference = candidates
            .where((candidate) => candidate.turn.state.isActive)
            .map((candidate) => candidate.evaluation.cellAdvantage)
            .reduce(_max);
        final winningDifferences = candidates
            .where(
              (candidate) => candidate.turn.state.outcome?.winner == player,
            )
            .map((candidate) => candidate.evaluation.cellAdvantage);
        final decision = agent.chooseMove(state);

        // This is a real counterexample to choosing by population alone.
        expect(bestActiveDifference, 16);
        expect(winningDifferences.reduce(_max), 12);
        expect(decision.turn.state.outcome!.winner, player);
        expect(decision.evaluation.score, terminalScore);
        expect(
          decision.evaluation.cellAdvantage,
          lessThan(bestActiveDifference),
        );
        expect(decision.evaluation.toJson()['score'], terminalScore);
        expect(
          decision.evaluation.toJson()['cellAdvantage'],
          decision.evaluation.selfCells - decision.evaluation.opponentCells,
        );
      },
    );

    test(
      'L2 win preference and pruning match brute force (${player.name})',
      () {
        final state = _winPreferenceState(player);
        const agent = TwoStepMaxDifferenceAgent();
        final candidates = agent.analyze(state);
        final oracle = _twoPlyOracle(state);

        for (final candidate in candidates) {
          expect(
            candidate.worstCaseScore,
            oracle[candidate.firstMove.representativeMove.coordinate],
          );
          final leaf = candidate.worstReply == null
              ? candidate.firstTurn.state
              : engine
                    .applyMove(candidate.firstTurn.state, candidate.worstReply!)
                    .state;
          expect(
            candidate.worstCaseCellAdvantage,
            leaf.board.population(player.cell) -
                leaf.board.population(player.opponent.cell),
          );
        }

        final bestScore = oracle.values.reduce(_max);
        final expectedTies = candidates
            .where((candidate) => candidate.worstCaseScore == bestScore)
            .toList();
        expect(bestScore, terminalScore);
        // The old heuristic can prefer a non-winning +13 leaf over these wins.
        expect(
          candidates.any(
            (candidate) =>
                candidate.worstCaseScore != terminalScore &&
                candidate.worstCaseCellAdvantage > 12,
          ),
          isTrue,
        );
        for (final seed in <int?>[null, 7]) {
          final decision = TwoStepMaxDifferenceAgent(
            tieBreakSeed: seed,
          ).chooseMove(state);
          expect(decision.worstCaseScore, bestScore);
          expect(oracle[decision.move.coordinate], bestScore);
          expect(decision.tiedBestSuccessorCount, expectedTies.length);
          expect(decision.toJson()['worstCaseScore'], terminalScore);
          expect(decision.worstCaseCellAdvantage, lessThan(terminalScore));
          if (seed == null) {
            expect(
              decision.move,
              expectedTies.first.firstMove.representativeMove,
            );
          }
        }
      },
    );
  }

  for (final fixture in [
    (
      black: 0,
      white: 0,
      victory: const EliminationVictory(),
      ply: 0,
      reason: OutcomeReason.mutualExtinction,
    ),
    (
      black: 3,
      white: 3,
      victory: TurnLimitPopulationVictory(2),
      ply: 2,
      reason: OutcomeReason.turnLimitTie,
    ),
    (
      black: 4,
      white: 3,
      victory: PopulationTargetVictory(3),
      ply: 0,
      reason: OutcomeReason.simultaneousTarget,
    ),
    (
      black: 399,
      white: 1,
      victory: const EliminationVictory(),
      ply: 0,
      reason: OutcomeReason.noLegalMoves,
    ),
  ]) {
    test('${fixture.reason.name} is neutral regardless of populations', () {
      final state = _populationState(
        black: fixture.black,
        white: fixture.white,
        victory: fixture.victory,
        ply: fixture.ply,
      );

      expect(state.outcome!.reason, fixture.reason);
      expect(evaluatePosition(state, Player.black), 0);
      expect(evaluatePosition(state, Player.white), 0);
    });
  }

  test('L2 retains a worst reply when every reply has winning utility', () {
    final state = _winPreferenceState(
      Player.black,
      victory: TurnLimitPopulationVictory(2),
    );
    final candidates = const TwoStepMaxDifferenceAgent().analyze(state);
    final forcedWins = candidates.where(
      (candidate) =>
          candidate.firstTurn.state.isActive &&
          candidate.worstCaseScore == terminalScore,
    );

    expect(forcedWins, isNotEmpty);
    for (final candidate in forcedWins) {
      expect(candidate.worstReply, isNotNull);
      expect(candidate.opponentLegalMoveCount, greaterThan(0));
    }
  });
}

int _max(int left, int right) => left > right ? left : right;

GameState _populationState({
  required int black,
  required int white,
  VictoryRule victory = const EliminationVictory(),
  int ply = 0,
}) {
  final rules = GameRules.standard(victory: victory);
  final board = Board(
    rows: GameRules.rows,
    columns: GameRules.columns,
    cells: [
      ...List.filled(black, CellState.black),
      ...List.filled(white, CellState.white),
      ...List.filled(GameRules.cellCount - black - white, CellState.empty),
    ],
  );
  final outcome = const GameEngine().evaluateOutcome(board, rules, ply: ply);
  return GameState(
    rules: rules,
    board: board,
    ply: ply,
    revision: ply,
    toMove: outcome == null ? Player.black : null,
    outcome: outcome,
  );
}

GameState _winPreferenceState(
  Player player, {
  VictoryRule victory = const EliminationVictory(),
}) {
  final cells = List.filled(GameRules.cellCount, CellState.empty);
  for (final (row, column) in [
    (8, 9),
    (9, 9),
    (10, 8),
    (10, 11),
    (11, 9),
    (11, 12),
    (12, 9),
    (12, 10),
    (12, 12),
  ]) {
    cells[row * GameRules.columns + column] = player.cell;
  }
  for (final (row, column) in [(8, 11), (9, 8)]) {
    cells[row * GameRules.columns + column] = player.opponent.cell;
  }
  return GameState(
    rules: GameRules.standard(victory: victory),
    board: Board(
      rows: GameRules.rows,
      columns: GameRules.columns,
      cells: cells,
    ),
    ply: player == Player.black ? 0 : 1,
    revision: player == Player.black ? 0 : 1,
    toMove: player,
    outcome: null,
  );
}

// Deliberately use the canonical engine and independent utility calculation;
// no production agent analysis, move ordering or pruning enters this oracle.
Map<Coordinate, int> _twoPlyOracle(GameState state) {
  const engine = GameEngine();
  final player = state.toMove!;
  final result = <Coordinate, int>{};
  final bySuccessor = <GameState, int>{};
  for (final coordinate in engine.legalMoves(state)) {
    final successor = engine
        .applyMove(
          state,
          GameMove(
            player: player,
            row: coordinate.row,
            column: coordinate.column,
            expectedRevision: state.revision,
          ),
        )
        .state;
    result[coordinate] = bySuccessor.putIfAbsent(successor, () {
      if (!successor.isActive) return _oracleScore(successor, player);
      var worst = terminalScore + 1;
      for (final reply in engine.legalMoves(successor)) {
        final leaf = engine
            .applyMove(
              successor,
              GameMove(
                player: successor.toMove!,
                row: reply.row,
                column: reply.column,
                expectedRevision: successor.revision,
              ),
            )
            .state;
        final score = _oracleScore(leaf, player);
        if (score < worst) worst = score;
      }
      return worst;
    });
  }
  return result;
}

int _oracleScore(GameState state, Player player) {
  final outcome = state.outcome;
  if (outcome == null) {
    return state.board.population(player.cell) -
        state.board.population(player.opponent.cell);
  }
  if (outcome.type == OutcomeType.draw) return 0;
  return outcome.winner == player ? 401 : -401;
}
