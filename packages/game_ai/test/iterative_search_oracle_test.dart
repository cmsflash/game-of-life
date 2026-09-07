import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

const _engine = GameEngine();
const _ampleTime = Duration(hours: 1);

void main() {
  final fixtures = <String, Board>{
    'mixed tactical groups': _board({
      const Coordinate(5, 5): CellState.black,
      const Coordinate(5, 6): CellState.black,
      const Coordinate(6, 5): CellState.white,
      const Coordinate(6, 6): CellState.black,
      const Coordinate(8, 7): CellState.white,
      const Coordinate(8, 8): CellState.white,
      const Coordinate(8, 9): CellState.black,
    }),
    'corner and edge groups': _board({
      const Coordinate(0, 0): CellState.white,
      const Coordinate(0, 1): CellState.black,
      const Coordinate(1, 0): CellState.black,
      const Coordinate(17, 19): CellState.black,
      const Coordinate(18, 18): CellState.white,
      const Coordinate(18, 19): CellState.white,
      const Coordinate(19, 18): CellState.white,
    }),
  };

  for (final fixture in fixtures.entries) {
    for (final player in Player.values) {
      for (final depth in [2, 3]) {
        test('${fixture.key}, ${player.name}, depth $depth matches oracle', () {
          final state = _state(fixture.value, player: player);
          final expected = _rootOracle(state, depth);
          for (final seed in <int?>[null, 0, 7]) {
            final decision = IterativeDeepeningAgent(
              minDepth: depth,
              maxDepth: depth,
              timeBudget: _ampleTime,
              tieBreakSeed: seed,
            ).chooseMove(state);
            expect(decision.completedDepth, depth);
            expect(decision.score, expected.score, reason: 'seed $seed');
            expect(
              expected.moves,
              contains(decision.move),
              reason: 'seed $seed',
            );
            if (seed == null) expect(decision.move, expected.moves.first);
          }
        });
      }
    }
  }

  test('cached search preserves optimal choices when root scores tie', () {
    final board = _board({
      const Coordinate(4, 4): CellState.black,
      const Coordinate(4, 5): CellState.black,
      const Coordinate(5, 4): CellState.white,
      const Coordinate(5, 5): CellState.white,
      const Coordinate(14, 14): CellState.white,
      const Coordinate(14, 15): CellState.white,
      const Coordinate(15, 14): CellState.black,
      const Coordinate(15, 15): CellState.black,
    });
    var cacheHits = 0;
    var cutoffs = 0;
    for (final player in Player.values) {
      final state = _state(board, player: player);
      final expected = _rootOracle(state, 3);
      expect(expected.moves.length, greaterThan(1));
      for (final seed in [0, 1, 2, 3]) {
        final decision = IterativeDeepeningAgent(
          maxDepth: 3,
          timeBudget: _ampleTime,
          tieBreakSeed: seed,
        ).chooseMove(state);
        expect(decision.score, expected.score);
        expect(expected.moves, contains(decision.move));
        cacheHits += decision.cacheHits;
        cutoffs += decision.cutoffs;
      }
    }
    expect(cacheHits, greaterThan(0));
    expect(cutoffs, greaterThan(0));
  });

  test(
    'nonopening turn-limit positions match terminal minimax for both colors',
    () {
      for (final player in Player.values) {
        final state = _state(
          fixtures.values.first,
          player: player,
          rules: GameRules.standard(victory: TurnLimitPopulationVictory(24)),
        );
        for (final depth in [2, 3]) {
          final expected = _rootOracle(state, depth);
          final actual = IterativeDeepeningAgent(
            minDepth: depth,
            maxDepth: depth,
            timeBudget: _ampleTime,
            tieBreakSeed: 19,
          ).chooseMove(state);
          expect(actual.score, expected.score);
          expect(expected.moves, contains(actual.move));
        }
      }
    },
  );

  test(
    'default minimum depth three actually progresses through depth four',
    () {
      const agent = IterativeDeepeningAgent(
        maxDepth: 4,
        timeBudget: _ampleTime,
      );
      final actual = agent.chooseMove(_engine.initialState());
      expect(agent.minDepth, 3);
      expect(actual.completedDepth, 4);
      expect(actual.attemptedDepth, 4);
      expect(actual.budgetExhausted, isFalse);
      expect(actual.cacheHits, greaterThan(0));
      expect(actual.cutoffs, greaterThan(0));
    },
  );
}

Board _board(Map<Coordinate, CellState> pieces) {
  final cells = List<CellState>.filled(GameRules.cellCount, CellState.empty);
  for (final piece in pieces.entries) {
    cells[piece.key.indexFor(GameRules.columns)] = piece.value;
  }
  return Board(rows: GameRules.rows, columns: GameRules.columns, cells: cells);
}

GameState _state(Board board, {required Player player, GameRules? rules}) {
  final ply = player == Player.black ? 22 : 23;
  return GameState(
    rules: rules ?? GameRules.standard(),
    board: board,
    ply: ply,
    revision: ply,
    toMove: player,
    outcome: null,
  );
}

({int score, List<GameMove> moves}) _rootOracle(GameState state, int depth) {
  var best = -terminalScore - 1;
  final moves = <GameMove>[];
  for (final successor in _engine.searchSuccessors(state)) {
    final value = _oracle(successor.state, depth - 1, state.toMove!);
    if (value > best) {
      best = value;
      moves
        ..clear()
        ..add(successor.move);
    } else if (value == best) {
      moves.add(successor.move);
    }
  }
  return (score: best, moves: moves);
}

// Deliberately no alpha/beta windows, move ordering or transposition cache.
// Engine successor generation is independently checked against every legal
// canonical move by game_engine/test/search_successors_test.dart.
int _oracle(GameState state, int depth, Player player) {
  if (!state.isActive || depth == 0) return evaluatePosition(state, player);
  final maximizing = state.toMove == player;
  var best = maximizing ? -terminalScore - 1 : terminalScore + 1;
  for (final successor in _engine.searchSuccessors(state)) {
    final value = _oracle(successor.state, depth - 1, player);
    if ((maximizing && value > best) || (!maximizing && value < best)) {
      best = value;
    }
  }
  return best;
}
