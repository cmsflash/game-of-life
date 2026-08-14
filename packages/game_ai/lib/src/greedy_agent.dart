import 'package:game_engine/game_engine.dart';

import 'agent.dart';
import 'evaluator.dart';

/// One exact successor state and every move that reaches it.
final class GreedyCandidate {
  GreedyCandidate({
    required this.representativeMove,
    required Iterable<GameMove> equivalentMoves,
    required this.turn,
    required this.evaluation,
  }) : equivalentMoves = List<GameMove>.unmodifiable(equivalentMoves);

  /// The row-major first move in this equivalence class.
  final GameMove representativeMove;
  final List<GameMove> equivalentMoves;
  final TurnResult turn;
  final PositionEvaluation evaluation;

  int get equivalentMoveCount => equivalentMoves.length;

  Map<String, Object?> toJson() => {
    'representativeMove': representativeMove.toJson(),
    'equivalentMoveCount': equivalentMoveCount,
    'evaluation': evaluation.toJson(),
  };
}

/// The selected greedy move and diagnostics about its one-ply search.
final class GreedyDecision implements AgentDecision {
  const GreedyDecision({
    required this.move,
    required this.turn,
    required this.evaluation,
    required this.legalMoveCount,
    required this.uniqueSuccessorCount,
    required this.equivalentMoveCount,
  });

  @override
  final GameMove move;
  final TurnResult turn;
  final PositionEvaluation evaluation;
  final int legalMoveCount;
  final int uniqueSuccessorCount;
  final int equivalentMoveCount;

  @override
  Map<String, Object?> toJson() => {
    'move': move.toJson(),
    'evaluation': evaluation.toJson(),
    'legalMoveCount': legalMoveCount,
    'uniqueSuccessorCount': uniqueSuccessorCount,
    'equivalentMoveCount': equivalentMoveCount,
  };
}

/// Deterministic one-ply search with exact successor deduplication.
///
/// Legal moves are applied with [GameEngine]. Moves that produce equal
/// [GameState] values are grouped before evaluation. The first row-major move
/// represents each group. Scores are maximized from the current player's
/// perspective, with the representative coordinate as the final tie-break.
final class GreedyAgent implements GameAgent {
  const GreedyAgent({
    this.name = 'greedy-v1',
    this.engine = const GameEngine(),
    this.evaluator = const HeuristicEvaluator(),
  });

  @override
  final String name;
  final GameEngine engine;
  final HeuristicEvaluator evaluator;

  List<GreedyCandidate> analyze(GameState state) {
    if (!state.isActive) {
      throw StateError('cannot analyze moves for a completed game');
    }
    final player = state.toMove!;
    final groups = <GameState, _CandidateGroup>{};

    for (final coordinate in engine.legalMoves(state)) {
      final move = GameMove(
        player: player,
        row: coordinate.row,
        column: coordinate.column,
        expectedRevision: state.revision,
      );
      final turn = engine.applyMove(state, move);
      final existing = groups[turn.state];
      if (existing == null) {
        groups[turn.state] = _CandidateGroup(turn, move);
      } else {
        existing.moves.add(move);
      }
    }

    if (groups.isEmpty) {
      throw StateError('active game has no legal moves');
    }

    final candidates = groups.values
        .map(
          (group) => GreedyCandidate(
            representativeMove: group.moves.first,
            equivalentMoves: group.moves,
            turn: group.turn,
            evaluation: evaluator.evaluate(group.turn.state, player),
          ),
        )
        .toList(growable: false);
    candidates.sort(
      (left, right) => left.representativeMove.coordinate.compareTo(
        right.representativeMove.coordinate,
      ),
    );
    return List<GreedyCandidate>.unmodifiable(candidates);
  }

  @override
  GreedyDecision chooseMove(GameState state) {
    final candidates = analyze(state);
    var best = candidates.first;
    for (final candidate in candidates.skip(1)) {
      final scoreComparison = candidate.evaluation.score.compareTo(
        best.evaluation.score,
      );
      if (scoreComparison > 0 ||
          (scoreComparison == 0 &&
              candidate.representativeMove.coordinate.compareTo(
                    best.representativeMove.coordinate,
                  ) <
                  0)) {
        best = candidate;
      }
    }

    final legalMoveCount = candidates.fold<int>(
      0,
      (total, candidate) => total + candidate.equivalentMoveCount,
    );
    return GreedyDecision(
      move: best.representativeMove,
      turn: best.turn,
      evaluation: best.evaluation,
      legalMoveCount: legalMoveCount,
      uniqueSuccessorCount: candidates.length,
      equivalentMoveCount: best.equivalentMoveCount,
    );
  }
}

final class _CandidateGroup {
  _CandidateGroup(this.turn, GameMove firstMove) : moves = [firstMove];

  final TurnResult turn;
  final List<GameMove> moves;
}
