# game_ai

Deterministic classical baselines and local experiment tooling for Life Duel.
The package imports `game_engine` directly, so AI-vs-AI games use the same pure
rules implementation as the product without Flutter, HTTP, persistence, or a
clock.

## Greedy baseline

`GreedyAgent` applies every legal move for the current player, groups moves
that produce exactly equal successor `GameState` values, evaluates each unique
successor once, and chooses the highest score. Equal scores use the row-major
first coordinate, so the result is fully reproducible.

The initial position has 396 legal coordinates but only 25 distinct successor
states. Exact deduplication is important because an isolated placement often
dies during the same turn and leaves the same board as many other placements.

The evaluator is deliberately explainable and currently includes:

- population advantage;
- cells that would survive with their current neighbor count;
- immediate three-neighbor birth potential;
- control of empty frontier cells; and
- same-color neighboring pairs.

Wins and losses override positional features. The feature weights are an
untuned baseline intended for measurement and later classical optimization.

## Run an AI-vs-AI game

The command-line experiment defaults to the bounded 100-ply population rules
because elimination-only games may repeat indefinitely. The reusable
`AiMatchRunner` remains rules-agnostic: callers can supply any supported rules
or a custom initial state, together with an explicit safety bound.

```bash
cd packages/game_ai
dart pub get
dart run bin/greedy_match.dart --pretty
```

Include every move, evaluation, legal-move count, and unique-successor count:

```bash
dart run bin/greedy_match.dart --max-plies=20 --trace --pretty
```

The output is JSON and contains the resolved rules, initial and final state
hashes, absolute plies, and the safety bound for reproducibility. Trace output
also includes every birth and death. `AiMatchRunner` accepts different
`GameAgent` implementations for future head-to-head experiments.

## Test

```bash
dart test
dart analyze --fatal-infos
```
