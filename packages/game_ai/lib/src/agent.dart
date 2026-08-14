import 'package:game_engine/game_engine.dart';

/// A player that selects one legal move from a complete game state.
abstract interface class GameAgent {
  String get name;

  AgentDecision chooseMove(GameState state);
}

/// The common result returned by an agent for one turn.
abstract interface class AgentDecision {
  GameMove get move;

  Map<String, Object?> toJson();
}
