import 'dart:convert';

import 'package:game_ai/experimental_search.dart';
import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';

void main(List<String> arguments) {
  final budget = arguments.isEmpty ? 10000 : int.parse(arguments.single);
  const engine = GameEngine();
  final states = [engine.initialState()];
  var state = states.first;
  for (var ply = 0; ply < 8 && state.isActive; ply++) {
    state = engine
        .applyMove(
          state,
          OneStepMaxDifferenceAgent(
            tieBreakSeed: 9000000 + ply,
          ).chooseMove(state).move,
        )
        .state;
    if (state.isActive && (ply == 3 || ply == 7)) states.add(state);
  }
  for (final state in states) {
    for (final profile in [
      for (final depth in [1, 2, 3, 4, 5, 8])
        (id: 'D$depth', depth: depth, full: 64, beam: 8),
      for (final full in [1, 2])
        for (final beam in [4, 8])
          (id: 'F${full}B$beam', depth: 8, full: full, beam: beam),
    ]) {
      final result = BudgetedSearchAgent(
        name: profile.id,
        maxDepth: profile.depth,
        fullWidthDepth: profile.full,
        beamWidth: profile.beam,
        transitionBudget: budget,
        tieBreakSeed: 9000000,
      ).chooseMove(state);
      print(
        jsonEncode({
          'ply': state.ply,
          'profile': profile.id,
          'completedDepth': result.completedDepth,
          'maxVisitedPly': result.maxVisitedPly,
          'usedBudget': result.successorEvaluations,
          'elapsedMs': result.elapsedMicroseconds / 1000,
          'score': result.score,
          'move': result.move.toJson(),
        }),
      );
    }
  }
}
