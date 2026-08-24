import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:game_engine/game_engine.dart';

import 'agent.dart';

/// The population objective optimized for one AI turn.
enum OneStepGreedyStrategy { maxSelfCells, minOpponentCells, maxCellAdvantage }

/// A percentage distribution used to select one strategy on every AI turn.
final class OneStepStrategyPercentages {
  const OneStepStrategyPercentages({
    required this.maxSelfCells,
    required this.minOpponentCells,
    required this.maxCellAdvantage,
  }) : assert(maxSelfCells >= 0),
       assert(minOpponentCells >= 0),
       assert(maxCellAdvantage >= 0),
       assert(maxSelfCells + minOpponentCells + maxCellAdvantage == 100);

  const OneStepStrategyPercentages.balanced()
    : maxSelfCells = 34,
      minOpponentCells = 33,
      maxCellAdvantage = 33;

  factory OneStepStrategyPercentages.pure(
    OneStepGreedyStrategy strategy,
  ) => switch (strategy) {
    OneStepGreedyStrategy.maxSelfCells => const OneStepStrategyPercentages(
      maxSelfCells: 100,
      minOpponentCells: 0,
      maxCellAdvantage: 0,
    ),
    OneStepGreedyStrategy.minOpponentCells => const OneStepStrategyPercentages(
      maxSelfCells: 0,
      minOpponentCells: 100,
      maxCellAdvantage: 0,
    ),
    OneStepGreedyStrategy.maxCellAdvantage => const OneStepStrategyPercentages(
      maxSelfCells: 0,
      minOpponentCells: 0,
      maxCellAdvantage: 100,
    ),
  };

  final int maxSelfCells;
  final int minOpponentCells;
  final int maxCellAdvantage;

  int get total => maxSelfCells + minOpponentCells + maxCellAdvantage;

  bool get isValid =>
      maxSelfCells >= 0 &&
      minOpponentCells >= 0 &&
      maxCellAdvantage >= 0 &&
      total == 100;

  factory OneStepStrategyPercentages.checked({
    required int maxSelfCells,
    required int minOpponentCells,
    required int maxCellAdvantage,
  }) {
    if (maxSelfCells < 0 ||
        minOpponentCells < 0 ||
        maxCellAdvantage < 0 ||
        maxSelfCells + minOpponentCells + maxCellAdvantage != 100) {
      throw ArgumentError.value(
        {
          'maxSelfCells': maxSelfCells,
          'minOpponentCells': minOpponentCells,
          'maxCellAdvantage': maxCellAdvantage,
        },
        'percentages',
        'strategy percentages must be non-negative and total 100',
      );
    }
    return OneStepStrategyPercentages(
      maxSelfCells: maxSelfCells,
      minOpponentCells: minOpponentCells,
      maxCellAdvantage: maxCellAdvantage,
    );
  }

  OneStepGreedyStrategy strategyForBucket(int bucket) {
    if (!isValid) {
      throw StateError('strategy percentages must total 100');
    }
    if (bucket < 0 || bucket >= 100) {
      throw RangeError.range(bucket, 0, 99, 'bucket');
    }
    if (bucket < maxSelfCells) return OneStepGreedyStrategy.maxSelfCells;
    if (bucket < maxSelfCells + minOpponentCells) {
      return OneStepGreedyStrategy.minOpponentCells;
    }
    return OneStepGreedyStrategy.maxCellAdvantage;
  }

  Map<String, Object?> toJson() => {
    'maxSelfCells': maxSelfCells,
    'minOpponentCells': minOpponentCells,
    'maxCellAdvantage': maxCellAdvantage,
  };
}

/// The three population measurements for one successor state.
final class OneStepPopulationEvaluation {
  const OneStepPopulationEvaluation({
    required this.selfCells,
    required this.opponentCells,
  });

  final int selfCells;
  final int opponentCells;

  int get cellAdvantage => selfCells - opponentCells;

  int scoreFor(OneStepGreedyStrategy strategy) => switch (strategy) {
    OneStepGreedyStrategy.maxSelfCells => selfCells,
    OneStepGreedyStrategy.minOpponentCells => -opponentCells,
    OneStepGreedyStrategy.maxCellAdvantage => cellAdvantage,
  };

  Map<String, Object?> toJson() => {
    'selfCells': selfCells,
    'opponentCells': opponentCells,
    'cellAdvantage': cellAdvantage,
  };
}

/// One exact successor state and every legal move that reaches it.
final class OneStepGreedyCandidate {
  OneStepGreedyCandidate({
    required this.representativeMove,
    required Iterable<GameMove> equivalentMoves,
    required this.turn,
    required this.evaluation,
  }) : equivalentMoves = List<GameMove>.unmodifiable(equivalentMoves);

  final GameMove representativeMove;
  final List<GameMove> equivalentMoves;
  final TurnResult turn;
  final OneStepPopulationEvaluation evaluation;

  int get equivalentMoveCount => equivalentMoves.length;
}

/// The selected move and diagnostics about its one-step search.
final class OneStepGreedyDecision implements AgentDecision {
  const OneStepGreedyDecision({
    required this.move,
    required this.turn,
    required this.strategy,
    required this.strategyBucket,
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
  final OneStepGreedyStrategy strategy;
  final int strategyBucket;
  final OneStepPopulationEvaluation evaluation;
  final int legalMoveCount;
  final int uniqueSuccessorCount;
  final int equivalentMoveCount;
  final int tiedBestSuccessorCount;
  final int? tieBreakSeed;

  @override
  Map<String, Object?> toJson() => {
    'move': move.toJson(),
    'strategy': strategy.name,
    'strategyBucket': strategyBucket,
    'evaluation': evaluation.toJson(),
    'legalMoveCount': legalMoveCount,
    'uniqueSuccessorCount': uniqueSuccessorCount,
    'equivalentMoveCount': equivalentMoveCount,
    'tiedBestSuccessorCount': tiedBestSuccessorCount,
    'tieBreakSeed': tieBreakSeed,
  };
}

/// A deterministic one-step greedy agent with a configurable strategy mix.
///
/// The state hash selects a stable bucket from 0 through 99. The configured
/// percentages map that bucket to exactly one population objective for the
/// turn. Every legal move is then applied with [GameEngine], equal successor
/// states are evaluated once, and row-major order breaks score ties.
final class OneStepGreedyAgent implements GameAgent {
  const OneStepGreedyAgent({
    this.name = 'one-step-greedy-v1',
    this.percentages = const OneStepStrategyPercentages.balanced(),
    this.tieBreakSeed,
    this.engine = const GameEngine(),
  }) : assert(tieBreakSeed == null || tieBreakSeed >= 0);

  @override
  final String name;
  final OneStepStrategyPercentages percentages;
  final int? tieBreakSeed;
  final GameEngine engine;

  int strategyBucket(GameState state) {
    final prefix = state.stateHash.substring(0, 8);
    return int.parse(prefix, radix: 16) % 100;
  }

  List<OneStepGreedyCandidate> analyze(GameState state) {
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
          return OneStepGreedyCandidate(
            representativeMove: group.moves.first,
            equivalentMoves: group.moves,
            turn: group.turn,
            evaluation: OneStepPopulationEvaluation(
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
    return List<OneStepGreedyCandidate>.unmodifiable(candidates);
  }

  @override
  OneStepGreedyDecision chooseMove(GameState state) {
    final bucket = strategyBucket(state);
    final strategy = percentages.strategyForBucket(bucket);
    final candidates = analyze(state);
    final bestScore = candidates
        .map((candidate) => candidate.evaluation.scoreFor(strategy))
        .reduce((left, right) => left > right ? left : right);
    final tiedBest = candidates
        .where(
          (candidate) => candidate.evaluation.scoreFor(strategy) == bestScore,
        )
        .toList(growable: false);
    final best = tiedBest[_tieBreakIndex(state, strategy, tiedBest.length)];

    final legalMoveCount = candidates.fold<int>(
      0,
      (total, candidate) => total + candidate.equivalentMoveCount,
    );
    return OneStepGreedyDecision(
      move: best.representativeMove,
      turn: best.turn,
      strategy: strategy,
      strategyBucket: bucket,
      evaluation: best.evaluation,
      legalMoveCount: legalMoveCount,
      uniqueSuccessorCount: candidates.length,
      equivalentMoveCount: best.equivalentMoveCount,
      tiedBestSuccessorCount: tiedBest.length,
      tieBreakSeed: tieBreakSeed,
    );
  }

  int _tieBreakIndex(
    GameState state,
    OneStepGreedyStrategy strategy,
    int candidateCount,
  ) {
    final seed = tieBreakSeed;
    if (seed == null || candidateCount == 1) return 0;
    if (seed < 0) throw StateError('tie-break seed must be non-negative');

    final digest = sha256.convert(
      utf8.encode('$seed:${state.stateHash}:${strategy.name}'),
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
