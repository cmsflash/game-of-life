import 'package:game_engine/game_engine.dart';

/// Identifies scoring semantics in decisions and experiment checkpoints.
const String evaluationVersion = 'terminalUtilityV1';

/// A proven result outranks every possible unfinished population difference.
const int terminalScore = GameRules.cellCount + 1;

/// Evaluates a position from [player]'s perspective under its actual outcome.
///
/// Population difference is only a heuristic for unfinished games. A win or
/// loss has fixed utility regardless of survivors; every draw is neutral.
int evaluatePosition(GameState state, Player player) {
  final outcome = state.outcome;
  if (outcome != null) {
    if (outcome.type == OutcomeType.draw) return 0;
    return outcome.winner == player ? terminalScore : -terminalScore;
  }
  return state.board.population(player.cell) -
      state.board.population(player.opponent.cell);
}
