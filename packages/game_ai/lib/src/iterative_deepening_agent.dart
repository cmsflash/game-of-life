import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:game_engine/game_engine.dart';

import 'agent.dart';
import 'position_evaluation.dart';

/// A cancelled search must never commit a partially computed move.
final class SearchCancelledException implements Exception {
  const SearchCancelledException();

  @override
  String toString() => 'AI search cancelled';
}

final class IterativeDeepeningDecision implements AgentDecision {
  const IterativeDeepeningDecision({
    required this.move,
    required this.turn,
    required this.score,
    required this.completedDepth,
    required this.attemptedDepth,
    required this.nodesVisited,
    required this.cacheHits,
    required this.cutoffs,
    required this.elapsed,
    required this.budgetExhausted,
    required this.tieBreakSeed,
  });

  @override
  final GameMove move;
  final TurnResult turn;
  final int score;
  final int completedDepth;
  final int attemptedDepth;
  final int nodesVisited;
  final int cacheHits;
  final int cutoffs;
  final Duration elapsed;
  final bool budgetExhausted;
  final int? tieBreakSeed;

  @override
  Map<String, Object?> toJson() => {
    'move': move.toJson(),
    'strategy': 'iterativeDeepening',
    'evaluationVersion': evaluationVersion,
    'score': score,
    'completedDepth': completedDepth,
    'attemptedDepth': attemptedDepth,
    'nodesVisited': nodesVisited,
    'cacheHits': cacheHits,
    'cutoffs': cutoffs,
    'elapsedMicroseconds': elapsed.inMicroseconds,
    'budgetExhausted': budgetExhausted,
    'tieBreakSeed': tieBreakSeed,
  };
}

/// Experimental level 2.9. Completes [minDepth] before enforcing the soft
/// budgets, then retains only fully completed deeper iterations.
///
/// The synchronous API is for headless experiments. The async API drives the
/// identical search in short slices, including on the web (no isolate needed).
final class IterativeDeepeningAgent implements GameAgent {
  const IterativeDeepeningAgent({
    this.name = 'ai-level-2.9',
    this.minDepth = 3,
    this.maxDepth = 64,
    this.timeBudget = const Duration(seconds: 1),
    this.maxNodes,
    this.tieBreakSeed,
    this.engine = const GameEngine(),
  });

  @override
  final String name;
  final int minDepth;
  final int maxDepth;
  final Duration timeBudget;

  /// Optional reproducible work budget; like time, it cannot truncate minDepth.
  final int? maxNodes;
  final int? tieBreakSeed;
  final GameEngine engine;

  @override
  IterativeDeepeningDecision chooseMove(GameState state) {
    final search = _start(state);
    final iterator = search.run().iterator;
    while (iterator.moveNext()) {
      // The iterator itself checks budgets at each resumable checkpoint.
    }
    return search.decision();
  }

  Future<IterativeDeepeningDecision> chooseMoveAsync(
    GameState state, {
    bool Function()? isCancelled,
  }) async {
    final search = _start(state, isCancelled: isCancelled);
    // Give the UI a chance to paint its thinking state before any search work.
    await Future<void>.delayed(Duration.zero);
    final iterator = search.run().iterator;
    final slice = Stopwatch()..start();
    while (iterator.moveNext()) {
      if (slice.elapsedMilliseconds >= 8) {
        await Future<void>.delayed(Duration.zero);
        slice.reset();
      }
    }
    search.checkCancellation();
    return search.decision();
  }

  _Search _start(GameState state, {bool Function()? isCancelled}) {
    if (!state.isActive) {
      throw StateError('cannot search a completed game');
    }
    if (minDepth < 1 || maxDepth < minDepth || maxDepth > 64) {
      throw ArgumentError('require 1 <= minDepth <= maxDepth <= 64');
    }
    if (timeBudget.isNegative || (maxNodes != null && maxNodes! < 1)) {
      throw ArgumentError(
        'search budgets must be non-negative (nodes positive)',
      );
    }
    if (tieBreakSeed != null && tieBreakSeed! < 0) {
      throw ArgumentError('tieBreakSeed must be non-negative');
    }
    return _Search(this, state, isCancelled);
  }
}

enum _Bound { exact, lower, upper }

typedef _Key = (Board, Player?, int, int?);

final class _Entry {
  const _Entry(this.score, this.bound);
  final int score;
  final _Bound bound;
}

final class _Node {
  _Node(this.state, this.depth, this.alpha, this.beta);
  final GameState state;
  final int depth;
  final int alpha;
  final int beta;
  late int score;
}

final class _BudgetExpired implements Exception {}

final class _Search {
  _Search(this.agent, this.root, this.isCancelled)
    : player = root.toMove!,
      watch = Stopwatch()..start();

  static const infinity = terminalScore + 1;
  static const maxTableEntries = 10000;
  final IterativeDeepeningAgent agent;
  final GameState root;
  final Player player;
  final bool Function()? isCancelled;
  final Stopwatch watch;
  final table = <_Key, _Entry>{};
  int nodes = 0;
  int cacheHits = 0;
  int cutoffs = 0;
  int completedDepth = 0;
  int attemptedDepth = 0;
  int score = 0;
  GameMove? bestMove;
  bool budgetExhausted = false;

  void checkCancellation() {
    if (isCancelled?.call() ?? false) {
      throw const SearchCancelledException();
    }
  }

  bool get overBudget =>
      watch.elapsed >= agent.timeBudget ||
      (agent.maxNodes != null && nodes >= agent.maxNodes!);

  void checkpoint() {
    checkCancellation();
    if (completedDepth >= agent.minDepth && overBudget) {
      budgetExhausted = true;
      throw _BudgetExpired();
    }
  }

  Iterable<void> run() sync* {
    try {
      for (var depth = 1; depth <= agent.maxDepth; depth++) {
        checkpoint();
        attemptedDepth = depth;
        yield* iteration(depth);
        completedDepth = depth;
        if (depth >= agent.minDepth && score.abs() == terminalScore) break;
      }
    } on _BudgetExpired {
      // The interrupted iteration has not replaced the last completed result.
    }
    budgetExhausted = budgetExhausted || overBudget;
    watch.stop();
  }

  Iterable<void> iteration(int depth) sync* {
    final successors = <SearchSuccessor>[];
    for (final successor in agent.engine.searchSuccessors(root)) {
      checkpoint();
      successors.add(successor);
      yield null;
    }
    if (successors.isEmpty) throw StateError('active game has no legal moves');
    order(successors, true);
    // Search the previous iteration's winner first without excluding any move.
    final previous = successors.indexWhere((item) => item.move == bestMove);
    if (previous > 0) successors.insert(0, successors.removeAt(previous));
    var bestScore = -infinity;
    final tied = <GameMove>[];
    for (final successor in successors) {
      final child = _Node(successor.state, depth - 1, bestScore, infinity);
      yield* visit(child);
      if (child.score > bestScore) {
        bestScore = child.score;
        tied
          ..clear()
          ..add(successor.move);
      } else if (child.score == bestScore) {
        tied.add(successor.move);
      }
    }
    // Commit both score and move together, only after the whole root completes.
    tied.sort((a, b) => a.coordinate.compareTo(b.coordinate));
    score = bestScore;
    bestMove = tied[tieIndex(tied.length, depth)];
  }

  Iterable<void> visit(_Node node) sync* {
    checkpoint();
    nodes++;
    yield null;
    if (!node.state.isActive || node.depth == 0) {
      node.score = evaluatePosition(node.state, player);
      return;
    }
    final victory = root.rules.victory;
    // No ply-dependent draw/repetition rule is invented. Turn-limit positions
    // additionally depend on how many game plies remain before adjudication.
    final remaining = victory is TurnLimitPopulationVictory
        ? victory.maxPlies - node.state.ply
        : null;
    final key = (node.state.board, node.state.toMove, node.depth, remaining);
    final entry = table[key];
    if (entry != null &&
        (entry.bound == _Bound.exact ||
            (entry.bound == _Bound.lower && entry.score > node.beta) ||
            (entry.bound == _Bound.upper && entry.score < node.alpha))) {
      cacheHits++;
      node.score = entry.score;
      return;
    }
    final maximizing = node.state.toMove == player;
    final successors = <SearchSuccessor>[];
    for (final successor in agent.engine.searchSuccessors(node.state)) {
      checkpoint();
      successors.add(successor);
      yield null;
    }
    if (successors.isEmpty) throw StateError('active game has no legal moves');
    order(successors, maximizing);
    var alpha = node.alpha;
    var beta = node.beta;
    var best = maximizing ? -infinity : infinity;
    for (final successor in successors) {
      final child = _Node(successor.state, node.depth - 1, alpha, beta);
      yield* visit(child);
      if (maximizing) {
        if (child.score > best) best = child.score;
        if (best > alpha) alpha = best;
      } else {
        if (child.score < best) best = child.score;
        if (best < beta) beta = best;
      }
      // Strict cutoff preserves exact ties at the root for seeded selection.
      if (alpha > beta) {
        cutoffs++;
        break;
      }
    }
    node.score = best;
    if (table.length < maxTableEntries || table.containsKey(key)) {
      table[key] = _Entry(
        best,
        best < node.alpha
            ? _Bound.upper
            : best > node.beta
            ? _Bound.lower
            : _Bound.exact,
      );
    }
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
    if (agent.tieBreakSeed == null || count == 1) return 0;
    final digest = sha256.convert(
      utf8.encode('${agent.tieBreakSeed}:${root.stateHash}:iterative:$depth'),
    );
    // Four bytes are exact on both native Dart and JavaScript.
    final prefix = digest.bytes.take(4).fold<int>(0, (a, b) => a * 256 + b);
    return prefix % count;
  }

  IterativeDeepeningDecision decision() {
    final move = bestMove;
    if (move == null) throw StateError('search did not complete an iteration');
    return IterativeDeepeningDecision(
      move: move,
      turn: agent.engine.applyMove(root, move),
      score: score,
      completedDepth: completedDepth,
      attemptedDepth: attemptedDepth,
      nodesVisited: nodes,
      cacheHits: cacheHits,
      cutoffs: cutoffs,
      elapsed: watch.elapsed,
      budgetExhausted: budgetExhausted,
      tieBreakSeed: agent.tieBreakSeed,
    );
  }
}
