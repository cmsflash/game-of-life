import 'package:game_engine/game_engine.dart' as engine;

/// A deterministic, client-side look at the board after one legal move.
///
/// The authoritative [engine.GameState] is left untouched until the caller
/// explicitly commits this preview.
final class MovePreview {
  const MovePreview({required this.move, required this.turn});

  factory MovePreview.simulate(
    engine.GameState game,
    engine.Coordinate coordinate,
  ) {
    final move = engine.GameMove(
      player: game.toMove!,
      row: coordinate.row,
      column: coordinate.column,
      expectedRevision: game.revision,
    );
    return MovePreview(
      move: move,
      turn: const engine.GameEngine().applyMove(game, move),
    );
  }

  final engine.GameMove move;
  final engine.TurnResult turn;

  engine.Coordinate get coordinate => move.coordinate;
  engine.Board get board => turn.state.board;

  List<engine.Coordinate> get births => turn.delta.evolution.births
      .map((birth) => birth.coordinate)
      .toList(growable: false);

  List<engine.Coordinate> get deaths => turn.delta.evolution.deaths
      .map((death) => death.coordinate)
      .toList(growable: false);

  List<engine.CellDeath> get deathEvents => turn.delta.evolution.deaths;
}
