import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:game_engine/game_engine.dart';

import 'agent.dart';
import 'one_step_max_difference_agent.dart';

/// One first move evaluated by a depth-two max-difference search.
final class TwoStepMaxDifferenceCandidate {
  const TwoStepMaxDifferenceCandidate({
    required this.firstMove,
    required this.firstTurn,
    required this.immediateCellAdvantage,
    required this.worstCaseCellAdvantage,
    required this.worstReply,
    required this.opponentLegalMoveCount,
    required this.opponentUniqueSuccessorCount,
  });

  final OneStepMaxDifferenceCandidate firstMove;
  final TurnResult firstTurn;
  final int immediateCellAdvantage;
  final int worstCaseCellAdvantage;
  final GameMove? worstReply;
  final int opponentLegalMoveCount;
  final int opponentUniqueSuccessorCount;
}

/// The selected move and diagnostics from a two-ply maximin search.
final class TwoStepMaxDifferenceDecision implements AgentDecision {
  const TwoStepMaxDifferenceDecision({
    required this.move,
    required this.turn,
    required this.immediateCellAdvantage,
    required this.worstCaseCellAdvantage,
    required this.worstReply,
    required this.legalMoveCount,
    required this.uniqueSuccessorCount,
    required this.equivalentMoveCount,
    required this.tiedBestSuccessorCount,
    required this.opponentLegalMoveCount,
    required this.opponentUniqueSuccessorCount,
    required this.tieBreakSeed,
  });

  @override
  final GameMove move;
  final TurnResult turn;
  final int immediateCellAdvantage;
  final int worstCaseCellAdvantage;
  final GameMove? worstReply;
  final int legalMoveCount;
  final int uniqueSuccessorCount;
  final int equivalentMoveCount;
  final int tiedBestSuccessorCount;
  final int opponentLegalMoveCount;
  final int opponentUniqueSuccessorCount;
  final int? tieBreakSeed;

  @override
  Map<String, Object?> toJson() => {
    'move': move.toJson(),
    'strategy': 'maxCellAdvantage',
    'searchPlies': 2,
    'immediateCellAdvantage': immediateCellAdvantage,
    'worstCaseCellAdvantage': worstCaseCellAdvantage,
    'worstReply': worstReply?.toJson(),
    'legalMoveCount': legalMoveCount,
    'uniqueSuccessorCount': uniqueSuccessorCount,
    'equivalentMoveCount': equivalentMoveCount,
    'tiedBestSuccessorCount': tiedBestSuccessorCount,
    'opponentLegalMoveCount': opponentLegalMoveCount,
    'opponentUniqueSuccessorCount': opponentUniqueSuccessorCount,
    'tieBreakSeed': tieBreakSeed,
  };
}

/// Looks ahead through one move and every legal opponent reply.
///
/// Each first move is scored by the AI's population advantage after the
/// opponent reply that minimizes that advantage. The agent chooses the move
/// with the largest such worst-case score. A move that ends the game is scored
/// immediately because it has no opponent reply.
final class TwoStepMaxDifferenceAgent implements GameAgent {
  const TwoStepMaxDifferenceAgent({
    this.name = 'ai-level-2',
    this.tieBreakSeed,
    this.engine = const GameEngine(),
  }) : assert(tieBreakSeed == null || tieBreakSeed >= 0);

  @override
  final String name;
  final int? tieBreakSeed;
  final GameEngine engine;

  /// Exhaustively scores every unique first-move successor.
  List<TwoStepMaxDifferenceCandidate> analyze(GameState state) {
    if (!state.isActive) {
      throw StateError('cannot analyze moves for a completed game');
    }
    final player = state.toMove!;
    final firstMoves = OneStepMaxDifferenceAgent(engine: engine).analyze(state);
    return List.unmodifiable(
      firstMoves.map(
        (firstMove) => _evaluateCandidate(player: player, firstMove: firstMove),
      ),
    );
  }

  @override
  TwoStepMaxDifferenceDecision chooseMove(GameState state) {
    if (!state.isActive) {
      throw StateError('cannot choose a move for a completed game');
    }
    final player = state.toMove!;
    final firstMoves = OneStepMaxDifferenceAgent(engine: engine).analyze(state);
    final searchOrder = [...firstMoves]
      ..sort((left, right) {
        final scoreComparison = _cellAdvantage(
          right.turn.state,
          player,
        ).compareTo(_cellAdvantage(left.turn.state, player));
        return scoreComparison != 0
            ? scoreComparison
            : left.representativeMove.coordinate.compareTo(
                right.representativeMove.coordinate,
              );
      });

    var bestScore = -GameRules.cellCount - 1;
    final best = <TwoStepMaxDifferenceCandidate>[];
    for (final firstMove in searchOrder) {
      final candidate = _evaluateCandidate(
        player: player,
        firstMove: firstMove,
        abandonBelow: bestScore,
      );
      if (candidate == null) continue;
      if (candidate.worstCaseCellAdvantage > bestScore) {
        bestScore = candidate.worstCaseCellAdvantage;
        best
          ..clear()
          ..add(candidate);
      } else if (candidate.worstCaseCellAdvantage == bestScore) {
        best.add(candidate);
      }
    }
    if (best.isEmpty) {
      throw StateError('active game has no legal moves');
    }
    best.sort(
      (left, right) => left.firstMove.representativeMove.coordinate.compareTo(
        right.firstMove.representativeMove.coordinate,
      ),
    );
    final selected = best[_tieBreakIndex(state, best.length)];
    final legalMoveCount = firstMoves.fold<int>(
      0,
      (total, candidate) => total + candidate.equivalentMoveCount,
    );
    return TwoStepMaxDifferenceDecision(
      move: selected.firstMove.representativeMove,
      turn: selected.firstTurn,
      immediateCellAdvantage: selected.immediateCellAdvantage,
      worstCaseCellAdvantage: selected.worstCaseCellAdvantage,
      worstReply: selected.worstReply,
      legalMoveCount: legalMoveCount,
      uniqueSuccessorCount: firstMoves.length,
      equivalentMoveCount: selected.firstMove.equivalentMoveCount,
      tiedBestSuccessorCount: best.length,
      opponentLegalMoveCount: selected.opponentLegalMoveCount,
      opponentUniqueSuccessorCount: selected.opponentUniqueSuccessorCount,
      tieBreakSeed: tieBreakSeed,
    );
  }

  TwoStepMaxDifferenceCandidate? _evaluateCandidate({
    required Player player,
    required OneStepMaxDifferenceCandidate firstMove,
    int? abandonBelow,
  }) {
    final firstTurn = firstMove.turn;
    final immediate = _cellAdvantage(firstTurn.state, player);
    if (!firstTurn.state.isActive) {
      return TwoStepMaxDifferenceCandidate(
        firstMove: firstMove,
        firstTurn: firstTurn,
        immediateCellAdvantage: immediate,
        worstCaseCellAdvantage: immediate,
        worstReply: null,
        opponentLegalMoveCount: 0,
        opponentUniqueSuccessorCount: 0,
      );
    }

    var worstScore = GameRules.cellCount + 1;
    GameMove? worstReply;
    var legalReplies = 0;
    final uniqueReplies = <GameState>{};
    for (final coordinate in engine.legalMoves(firstTurn.state)) {
      final move = GameMove(
        player: firstTurn.state.toMove!,
        row: coordinate.row,
        column: coordinate.column,
        expectedRevision: firstTurn.state.revision,
      );
      final reply = engine.applyMove(firstTurn.state, move);
      legalReplies++;
      uniqueReplies.add(reply.state);
      final score = _cellAdvantage(reply.state, player);
      if (score < worstScore) {
        worstScore = score;
        worstReply = move;
        if (abandonBelow != null && worstScore < abandonBelow) return null;
      }
    }
    return TwoStepMaxDifferenceCandidate(
      firstMove: firstMove,
      firstTurn: firstTurn,
      immediateCellAdvantage: immediate,
      worstCaseCellAdvantage: worstScore,
      worstReply: worstReply,
      opponentLegalMoveCount: legalReplies,
      opponentUniqueSuccessorCount: uniqueReplies.length,
    );
  }

  int _cellAdvantage(GameState state, Player player) =>
      state.board.population(player.cell) -
      state.board.population(player.opponent.cell);

  int _tieBreakIndex(GameState state, int candidateCount) {
    final seed = tieBreakSeed;
    if (seed == null || candidateCount == 1) return 0;
    if (seed < 0) throw StateError('tie-break seed must be non-negative');
    final digest = sha256.convert(
      utf8.encode('$seed:${state.stateHash}:maxCellAdvantageDepth2'),
    );
    final prefix = digest.bytes
        .take(8)
        .fold<int>(0, (value, byte) => (value << 8) | byte);
    return prefix % candidateCount;
  }
}
