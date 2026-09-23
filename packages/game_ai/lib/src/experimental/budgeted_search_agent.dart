import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:game_engine/game_engine.dart';

import '../agent.dart';
import '../position_evaluation.dart';

/// Diagnostics for a completed, strictly budgeted offline search.
final class BudgetedSearchDecision implements AgentDecision {
  const BudgetedSearchDecision({
    required this.move,
    required this.score,
    required this.completedDepth,
    required this.attemptedDepth,
    required this.maxVisitedPly,
    required this.successorEvaluations,
    required this.nodesVisited,
    required this.cacheHits,
    required this.cutoffs,
    required this.elapsed,
    required this.budgetExhausted,
    required this.agent,
  });

  @override
  final GameMove move;
  final int score;

  /// Last fully completed requested horizon; terminal lines can stop earlier.
  final int completedDepth;
  final int attemptedDepth;

  /// Deepest recursive node visited, measured in plies from the root.
  ///
  /// Includes terminal, leaf, and cached nodes in all iterations, including an
  /// aborted partial iteration. Generated candidates not recursively visited
  /// do not count, and this is not the depth that supplied the returned move.
  final int maxVisitedPly;
  final int successorEvaluations;
  final int nodesVisited;
  final int cacheHits;
  final int cutoffs;
  final Duration elapsed;
  final bool budgetExhausted;
  final BudgetedSearchAgent agent;

  int get elapsedMicroseconds => elapsed.inMicroseconds;

  @override
  Map<String, Object?> toJson() => {
    'move': move.toJson(),
    'strategy': 'budgetedSearch',
    'evaluationVersion': evaluationVersion,
    'budgetMetric': 'generatedUniqueSuccessors',
    'name': agent.name,
    'maxDepth': agent.maxDepth,
    'transitionBudget': agent.transitionBudget,
    'fullWidthDepth': agent.fullWidthDepth,
    'beamWidth': agent.beamWidth,
    'tieBreakSeed': agent.tieBreakSeed,
    'score': score,
    'completedDepth': completedDepth,
    'attemptedDepth': attemptedDepth,
    'maxVisitedPly': maxVisitedPly,
    'successorEvaluations': successorEvaluations,
    'nodesVisited': nodesVisited,
    'cacheHits': cacheHits,
    'cutoffs': cutoffs,
    'elapsedMicroseconds': elapsedMicroseconds,
    'budgetExhausted': budgetExhausted,
  };
}

/// Iterative alpha-beta for experiments with a strict total transition budget.
///
/// Every generated distinct successor is charged, including candidates used
/// only for ordering or rejected by the beam, and regeneration in later
/// iterations. Root moves are always full width. At other nodes, children are
/// ranked by terminal-aware evaluation and limited to [beamWidth] once their
/// parent's distance from the root reaches [fullWidthDepth].
///
/// Only a fully completed root iteration supplies the returned move. There is
/// no minimum-depth override, time cutoff, or claim that a selective terminal
/// score proves a forced result in the full legal game.
final class BudgetedSearchAgent implements GameAgent {
  const BudgetedSearchAgent({
    required this.maxDepth,
    required this.transitionBudget,
    this.fullWidthDepth = 64,
    this.beamWidth = 8,
    this.tieBreakSeed,
    this.name = 'budgeted-search',
  });

  final int maxDepth;
  final int transitionBudget;
  final int fullWidthDepth;
  final int beamWidth;
  final int? tieBreakSeed;
  @override
  final String name;

  @override
  BudgetedSearchDecision chooseMove(GameState state) {
    if (!state.isActive) throw StateError('cannot search a completed game');
    if (maxDepth < 1 || maxDepth > 64) {
      throw ArgumentError('require 1 <= maxDepth <= 64');
    }
    if (transitionBudget < GameRules.cellCount) {
      throw ArgumentError('transitionBudget must be at least 400');
    }
    if (fullWidthDepth < 1 || beamWidth < 1) {
      throw ArgumentError('fullWidthDepth and beamWidth must be positive');
    }
    if (tieBreakSeed != null && tieBreakSeed! < 0) {
      throw ArgumentError('tieBreakSeed must be non-negative');
    }
    return _BudgetedSearch(this, state).run();
  }
}

enum _Bound { exact, lower, upper }

typedef _Key = (Board, Player?, int, int, int?);

final class _Entry {
  const _Entry(this.score, this.bound);
  final int score;
  final _Bound bound;
}

final class _TransitionBudgetExpired implements Exception {}

final class _BudgetedSearch {
  _BudgetedSearch(this.agent, this.root) : player = root.toMove!;

  static const engine = GameEngine();
  static const infinity = terminalScore + 1;
  static const maxTableEntries = 10000;
  final BudgetedSearchAgent agent;
  final GameState root;
  final Player player;
  final table = <_Key, _Entry>{};
  int successorEvaluations = 0;
  int nodes = 0;
  int cacheHits = 0;
  int cutoffs = 0;
  int completedDepth = 0;
  int attemptedDepth = 0;
  int maxVisitedPly = 0;
  int score = 0;
  GameMove? bestMove;
  bool budgetExhausted = false;

  BudgetedSearchDecision run() {
    final watch = Stopwatch()..start();
    try {
      for (var depth = 1; depth <= agent.maxDepth; depth++) {
        attemptedDepth = depth;
        iteration(depth);
        completedDepth = depth;
      }
    } on _TransitionBudgetExpired {
      budgetExhausted = true;
    }
    watch.stop();
    final move = bestMove;
    if (move == null) throw StateError('active game has no legal moves');
    return BudgetedSearchDecision(
      move: move,
      score: score,
      completedDepth: completedDepth,
      attemptedDepth: attemptedDepth,
      maxVisitedPly: maxVisitedPly,
      successorEvaluations: successorEvaluations,
      nodesVisited: nodes,
      cacheHits: cacheHits,
      cutoffs: cutoffs,
      elapsed: watch.elapsed,
      budgetExhausted:
          budgetExhausted || successorEvaluations == agent.transitionBudget,
      agent: agent,
    );
  }

  void iteration(int depth) {
    final successors = generate(root);
    if (successors.isEmpty) throw StateError('active game has no legal moves');
    order(successors, true);
    final previous = successors.indexWhere((item) => item.move == bestMove);
    if (previous > 0) successors.insert(0, successors.removeAt(previous));
    var best = -infinity;
    final tied = <GameMove>[];
    for (final successor in successors) {
      final value = visit(successor.state, depth - 1, 1, best, infinity);
      if (value > best) {
        best = value;
        tied
          ..clear()
          ..add(successor.move);
      } else if (value == best) {
        tied.add(successor.move);
      }
    }
    tied.sort((a, b) => a.coordinate.compareTo(b.coordinate));
    // A failed generation anywhere above leaves this pair unchanged.
    score = best;
    bestMove = tied[tieIndex(tied.length, depth)];
  }

  List<SearchSuccessor> generate(GameState state) {
    final successors = <SearchSuccessor>[];
    final legalPlacementCount = state.board.population(CellState.empty);
    final iterator = engine.searchSuccessors(state).iterator;
    while (successors.length < legalPlacementCount) {
      // Check BEFORE moveNext: probing for exhaustion might create one more
      // successor. At the cap, conservatively discard the partial iteration.
      if (successorEvaluations >= agent.transitionBudget) {
        throw _TransitionBudgetExpired();
      }
      if (!iterator.moveNext()) break;
      successorEvaluations++;
      successors.add(iterator.current);
    }
    return successors;
  }

  int visit(GameState state, int depth, int plyFromRoot, int alpha, int beta) {
    nodes++;
    if (plyFromRoot > maxVisitedPly) maxVisitedPly = plyFromRoot;
    if (!state.isActive || depth == 0) return evaluatePosition(state, player);
    final victory = root.rules.victory;
    final remainingPlies = victory is TurnLimitPopulationVictory
        ? victory.maxPlies - state.ply
        : null;
    // The same board/depth can have a different selective tree in another
    // iteration. Include how many further levels remain full width.
    final fullWidthRemaining = agent.beamWidth >= GameRules.cellCount
        ? depth
        : (agent.fullWidthDepth - plyFromRoot).clamp(0, depth);
    final key = (
      state.board,
      state.toMove,
      depth,
      fullWidthRemaining,
      remainingPlies,
    );
    final cached = table[key];
    if (cached != null &&
        (cached.bound == _Bound.exact ||
            (cached.bound == _Bound.lower && cached.score > beta) ||
            (cached.bound == _Bound.upper && cached.score < alpha))) {
      cacheHits++;
      return cached.score;
    }
    final maximizing = state.toMove == player;
    final successors = generate(state);
    if (successors.isEmpty) throw StateError('active game has no legal moves');
    order(successors, maximizing);
    final retained = plyFromRoot < agent.fullWidthDepth
        ? successors.length
        : successors.length < agent.beamWidth
        ? successors.length
        : agent.beamWidth;
    final originalAlpha = alpha;
    final originalBeta = beta;
    var best = maximizing ? -infinity : infinity;
    for (var index = 0; index < retained; index++) {
      final value = visit(
        successors[index].state,
        depth - 1,
        plyFromRoot + 1,
        alpha,
        beta,
      );
      if (maximizing) {
        if (value > best) best = value;
        if (best > alpha) alpha = best;
      } else {
        if (value < best) best = value;
        if (best < beta) beta = best;
      }
      // Equality stays searchable so a bound cannot invent a root tie.
      if (alpha > beta) {
        cutoffs++;
        break;
      }
    }
    if (table.length < maxTableEntries || table.containsKey(key)) {
      table[key] = _Entry(
        best,
        best < originalAlpha
            ? _Bound.upper
            : best > originalBeta
            ? _Bound.lower
            : _Bound.exact,
      );
    }
    return best;
  }

  void order(List<SearchSuccessor> successors, bool maximizing) {
    final scores = {
      for (final successor in successors)
        successor.move: evaluatePosition(successor.state, player),
    };
    successors.sort((a, b) {
      final comparison = maximizing
          ? scores[b.move]!.compareTo(scores[a.move]!)
          : scores[a.move]!.compareTo(scores[b.move]!);
      return comparison != 0
          ? comparison
          : a.move.coordinate.compareTo(b.move.coordinate);
    });
  }

  int tieIndex(int count, int depth) {
    final seed = agent.tieBreakSeed;
    if (seed == null || count == 1) return 0;
    final digest = sha256.convert(
      utf8.encode('$seed:${root.stateHash}:budgeted:$depth'),
    );
    final prefix = digest.bytes.take(4).fold<int>(0, (a, b) => a * 256 + b);
    return prefix % count;
  }
}
