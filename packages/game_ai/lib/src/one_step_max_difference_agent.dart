import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:game_engine/game_engine.dart';

import 'agent.dart';

/// The population difference for one successor state.
final class OneStepDifferenceEvaluation {
  const OneStepDifferenceEvaluation({
    required this.selfCells,
    required this.opponentCells,
  });

  final int selfCells;
  final int opponentCells;

  int get cellAdvantage => selfCells - opponentCells;

  Map<String, Object?> toJson() => {
    'selfCells': selfCells,
    'opponentCells': opponentCells,
    'cellAdvantage': cellAdvantage,
  };
}

/// One exact successor state and every legal move that reaches it.
final class OneStepMaxDifferenceCandidate {
  OneStepMaxDifferenceCandidate({
    required this.representativeMove,
    required Iterable<GameMove> equivalentMoves,
    required this.turn,
    required this.evaluation,
  }) : equivalentMoves = List<GameMove>.unmodifiable(equivalentMoves);

  final GameMove representativeMove;
  final List<GameMove> equivalentMoves;
  final TurnResult turn;
  final OneStepDifferenceEvaluation evaluation;

  int get equivalentMoveCount => equivalentMoves.length;
}

/// The selected move and diagnostics from a one-ply Max difference search.
final class OneStepMaxDifferenceDecision implements AgentDecision {
  const OneStepMaxDifferenceDecision({
    required this.move,
    required this.turn,
    required this.evaluation,
    required this.legalMoveCount,
    required this.uniqueSuccessorCount,
    required this.equivalentMoveCount,
    required this.tiedBestSuccessorCount,
    required this.tieBreakSeed,
  });

  @override
  final GameMove move;
  final TurnResult turn;
  final OneStepDifferenceEvaluation evaluation;
  final int legalMoveCount;
  final int uniqueSuccessorCount;
  final int equivalentMoveCount;
  final int tiedBestSuccessorCount;
  final int? tieBreakSeed;

  @override
  Map<String, Object?> toJson() => {
    'move': move.toJson(),
    'strategy': 'maxCellAdvantage',
    'searchPlies': 1,
    'evaluation': evaluation.toJson(),
    'legalMoveCount': legalMoveCount,
    'uniqueSuccessorCount': uniqueSuccessorCount,
    'equivalentMoveCount': equivalentMoveCount,
    'tiedBestSuccessorCount': tiedBestSuccessorCount,
    'tieBreakSeed': tieBreakSeed,
  };
}

/// AI level 1: maximize own-minus-opponent population after one move.
final class OneStepMaxDifferenceAgent implements GameAgent {
  const OneStepMaxDifferenceAgent({
    this.name = 'ai-level-1',
    this.tieBreakSeed,
    this.engine = const GameEngine(),
  }) : assert(tieBreakSeed == null || tieBreakSeed >= 0);

  @override
  final String name;
  final int? tieBreakSeed;
  final GameEngine engine;

  List<OneStepMaxDifferenceCandidate> analyze(GameState state) {
    if (!state.isActive) {
      throw StateError('cannot analyze moves for a completed game');
    }
    final player = state.toMove!;
    final groups = <GameState, _OneStepCandidateGroup>{};
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
        groups[turn.state] = _OneStepCandidateGroup(turn, move);
      } else {
        existing.moves.add(move);
      }
    }
    if (groups.isEmpty) {
      throw StateError('active game has no legal moves');
    }
    final candidates = groups.values
        .map((group) {
          final board = group.turn.state.board;
          return OneStepMaxDifferenceCandidate(
            representativeMove: group.moves.first,
            equivalentMoves: group.moves,
            turn: group.turn,
            evaluation: OneStepDifferenceEvaluation(
              selfCells: board.population(player.cell),
              opponentCells: board.population(player.opponent.cell),
            ),
          );
        })
        .toList(growable: false);
    candidates.sort(
      (left, right) => left.representativeMove.coordinate.compareTo(
        right.representativeMove.coordinate,
      ),
    );
    return List.unmodifiable(candidates);
  }

  @override
  OneStepMaxDifferenceDecision chooseMove(GameState state) {
    final candidates = analyze(state);
    final bestScore = candidates
        .map((candidate) => candidate.evaluation.cellAdvantage)
        .reduce((left, right) => left > right ? left : right);
    final tiedBest = candidates
        .where((candidate) => candidate.evaluation.cellAdvantage == bestScore)
        .toList(growable: false);
    final best = tiedBest[_tieBreakIndex(state, tiedBest.length)];
    final legalMoveCount = candidates.fold<int>(
      0,
      (total, candidate) => total + candidate.equivalentMoveCount,
    );
    return OneStepMaxDifferenceDecision(
      move: best.representativeMove,
      turn: best.turn,
      evaluation: best.evaluation,
      legalMoveCount: legalMoveCount,
      uniqueSuccessorCount: candidates.length,
      equivalentMoveCount: best.equivalentMoveCount,
      tiedBestSuccessorCount: tiedBest.length,
      tieBreakSeed: tieBreakSeed,
    );
  }

  int _tieBreakIndex(GameState state, int candidateCount) {
    final seed = tieBreakSeed;
    if (seed == null || candidateCount == 1) return 0;
    if (seed < 0) throw StateError('tie-break seed must be non-negative');
    final digest = sha256.convert(
      utf8.encode('$seed:${state.stateHash}:maxCellAdvantageDepth1'),
    );
    final prefix = digest.bytes
        .take(8)
        .fold<int>(0, (value, byte) => (value << 8) | byte);
    return prefix % candidateCount;
  }
}

final class _OneStepCandidateGroup {
  _OneStepCandidateGroup(this.turn, GameMove firstMove) : moves = [firstMove];

  final TurnResult turn;
  final List<GameMove> moves;
}
