import 'package:game_engine/game_engine.dart';

import 'agent.dart';

/// One recorded AI decision and the authoritative transition it produced.
final class AiTurnRecord {
  const AiTurnRecord({
    required this.agentName,
    required this.decision,
    required this.turn,
  });

  final String agentName;
  final AgentDecision decision;
  final TurnResult turn;

  Map<String, Object?> toJson() => {
    'agent': agentName,
    'decision': decision.toJson(),
    'resultingPly': turn.state.ply,
    'resultingPositionHash': turn.state.positionHash,
    'delta': turn.delta.toJson(),
  };
}

/// Reproducible output from one local AI-vs-AI game.
final class AiMatchResult {
  AiMatchResult({
    required this.blackAgent,
    required this.whiteAgent,
    required this.initialState,
    required this.finalState,
    required Iterable<AiTurnRecord> turns,
    required this.truncated,
    required this.safetyMaxPlies,
  }) : turns = List<AiTurnRecord>.unmodifiable(turns);

  final String blackAgent;
  final String whiteAgent;
  final GameState initialState;
  final GameState finalState;
  final List<AiTurnRecord> turns;

  /// True only when the runner's safety bound stopped an otherwise active game.
  final bool truncated;
  final int safetyMaxPlies;

  Map<String, Object?> toJson({bool includeTurns = false}) => {
    'blackAgent': blackAgent,
    'whiteAgent': whiteAgent,
    'rules': initialState.rules.toJson(),
    'rulesHash': initialState.rules.rulesHash,
    'initialPositionHash': initialState.positionHash,
    'initialStateHash': initialState.stateHash,
    'initialPly': initialState.ply,
    'finalPly': finalState.ply,
    'plies': finalState.ply - initialState.ply,
    'safetyMaxPlies': safetyMaxPlies,
    'truncated': truncated,
    'outcome': finalState.outcome?.toJson(),
    'blackPopulation': finalState.blackPopulation,
    'whitePopulation': finalState.whitePopulation,
    'finalPositionHash': finalState.positionHash,
    'finalStateHash': finalState.stateHash,
    if (includeTurns)
      'turns': turns.map((turn) => turn.toJson()).toList(growable: false),
  };
}

/// Runs two agents directly against the standalone deterministic engine.
final class AiMatchRunner {
  const AiMatchRunner({
    required this.black,
    required this.white,
    this.engine = const GameEngine(),
  });

  final GameAgent black;
  final GameAgent white;
  final GameEngine engine;

  AiMatchResult play({
    GameRules? rules,
    GameState? initialState,
    required int safetyMaxPlies,
  }) {
    if (rules != null && initialState != null) {
      throw ArgumentError('provide rules or initialState, not both');
    }
    final initial = initialState ?? engine.initialState(rules);
    if (safetyMaxPlies <= initial.ply) {
      throw ArgumentError.value(
        safetyMaxPlies,
        'safetyMaxPlies',
        'must be greater than the initial ply',
      );
    }

    var state = initial;
    final records = <AiTurnRecord>[];
    while (state.isActive && state.ply < safetyMaxPlies) {
      final player = state.toMove!;
      final agent = player == Player.black ? black : white;
      final decision = agent.chooseMove(state);
      final validation = engine.validateMove(state, decision.move);
      if (!validation.isValid) {
        throw StateError(
          'agent ${agent.name} returned an illegal move: '
          '${validation.code?.name}: ${validation.message}',
        );
      }
      final turn = engine.applyMove(state, decision.move);
      records.add(
        AiTurnRecord(agentName: agent.name, decision: decision, turn: turn),
      );
      state = turn.state;
    }

    return AiMatchResult(
      blackAgent: black.name,
      whiteAgent: white.name,
      initialState: initial,
      finalState: state,
      turns: records,
      truncated: state.isActive,
      safetyMaxPlies: safetyMaxPlies,
    );
  }
}
