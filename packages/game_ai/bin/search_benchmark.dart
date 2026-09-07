import 'dart:convert';

import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';

/// A bounded, headless smoke benchmark, not a win-rate tournament.
void main() {
  const engine = GameEngine();
  var state = engine.initialState();
  final positions = <GameState>[state];
  for (var ply = 0; ply < 12 && state.isActive; ply++) {
    final move = OneStepMaxDifferenceAgent(tieBreakSeed: ply).chooseMove(state);
    state = engine.applyMove(state, move.move).state;
    if (state.isActive && (ply == 3 || ply == 7 || ply == 11)) {
      positions.add(state);
    }
  }
  for (final position in positions) {
    for (final agent in <GameAgent>[
      const OneStepMaxDifferenceAgent(),
      const TwoStepMaxDifferenceAgent(),
      const IterativeDeepeningAgent(timeBudget: Duration.zero),
      const IterativeDeepeningAgent(),
    ]) {
      final watch = Stopwatch()..start();
      final decision = agent.chooseMove(position);
      watch.stop();
      print(
        jsonEncode({
          'agent': agent.name,
          'ply': position.ply,
          'stateHash': position.stateHash,
          'elapsedMicroseconds': watch.elapsedMicroseconds,
          'decision': decision.toJson(),
        }),
      );
    }
  }
}
