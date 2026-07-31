# game_engine

Pure Dart rules engine for Life Duel, a deterministic two-player variant of
Conway's Game of Life.

The package has no Flutter, network, storage, clock, or random-number
dependencies. It is shared by the Flutter client, authoritative backend, CLI,
replay tooling, and AI environments.

## Rules

- A finite 20×20 board with empty, Black, and White cells.
- The centered stable 2×2 block starts with diagonal ownership; Black moves
  first.
- A turn places the current player's color on an empty cell and then performs
  one simultaneous B3/S23 evolution.
- A survivor retains its color. Every birth takes the majority color of its
  exactly three live neighbors.
- Placement may die during the same turn. Passing and occupied placement are
  illegal.
- Elimination is always terminal. Optional population-target and turn-limit
  population rules add other terminal conditions.

## Usage

```dart
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

print(turn.state.toMove); // Player.white
```

Use `validateMove` or `tryApplyMove` when exceptions are undesirable.
`applyMove` throws a typed `GameRuleViolation` for an invalid move.

All models defensively copy collection input and expose JSON serialization.
Rules, positions, and states have deterministic SHA-256 hashes. Move
concurrency must use `revision`, because an isolated placement can evolve away
and recreate an earlier position.

The engine accepts only rules version 3 with `strictNeighborMajority` birth
ownership.
