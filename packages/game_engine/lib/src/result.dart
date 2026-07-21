import 'board.dart';
import 'state.dart';

final class PlacementEvent {
  const PlacementEvent({required this.coordinate, required this.player});

  final Coordinate coordinate;
  final Player player;

  Map<String, Object?> toJson() => {
    'coordinate': coordinate.toJson(),
    'player': player.name,
  };
}

final class CellBirth {
  const CellBirth({required this.coordinate, required this.player});

  final Coordinate coordinate;
  final Player player;

  Map<String, Object?> toJson() => {
    'coordinate': coordinate.toJson(),
    'player': player.name,
  };
}

final class CellDeath {
  const CellDeath({required this.coordinate, required this.player});

  final Coordinate coordinate;
  final Player player;

  Map<String, Object?> toJson() => {
    'coordinate': coordinate.toJson(),
    'player': player.name,
  };
}

final class EvolutionDelta {
  EvolutionDelta({
    required Iterable<CellBirth> births,
    required Iterable<CellDeath> deaths,
  }) : births = List<CellBirth>.unmodifiable(births),
       deaths = List<CellDeath>.unmodifiable(deaths);

  final List<CellBirth> births;
  final List<CellDeath> deaths;

  Map<String, Object?> toJson() => {
    'births': births.map((birth) => birth.toJson()).toList(growable: false),
    'deaths': deaths.map((death) => death.toJson()).toList(growable: false),
  };
}

final class EvolutionResult {
  const EvolutionResult({required this.board, required this.delta});

  final Board board;
  final EvolutionDelta delta;

  Map<String, Object?> toJson() => {
    'board': board.toJson(),
    'delta': delta.toJson(),
  };
}

final class TurnDelta {
  const TurnDelta({required this.placement, required this.evolution});

  final PlacementEvent placement;
  final EvolutionDelta evolution;

  Map<String, Object?> toJson() => {
    'placement': placement.toJson(),
    'evolution': evolution.toJson(),
  };
}

final class TurnResult {
  const TurnResult({required this.state, required this.delta});

  final GameState state;
  final TurnDelta delta;

  Map<String, Object?> toJson() => {
    'state': state.toJson(),
    'delta': delta.toJson(),
  };
}

sealed class ApplyMoveResult {
  const ApplyMoveResult();
}

final class AppliedMove extends ApplyMoveResult {
  const AppliedMove(this.turn);

  final TurnResult turn;
}

final class RejectedMove extends ApplyMoveResult {
  const RejectedMove(this.validation);

  final MoveValidation validation;
}
