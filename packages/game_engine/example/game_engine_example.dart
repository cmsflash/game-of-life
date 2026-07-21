import 'package:game_engine/game_engine.dart';

void main() {
  const engine = GameEngine();
  final initial = engine.initialState();
  final turn = engine.applyMove(
    initial,
    const GameMove(
      player: Player.black,
      row: 0,
      column: 0,
      expectedRevision: 0,
    ),
  );

  print('Revision: ${turn.state.revision}');
  print('Next player: ${turn.state.toMove?.name}');
  print(
    'Placed cell died: '
    '${turn.state.board.at(0, 0) == CellState.empty}',
  );
}
