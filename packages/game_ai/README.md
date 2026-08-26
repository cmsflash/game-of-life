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

## One-step population AI

`OneStepGreedyAgent` selects one population strategy on every turn, applies
every legal move with the canonical engine, and greedily chooses the best
one-step successor for that strategy. The strategy mix is configured as three
percentages that total 100:

- maximize the AI's living cells;
- minimize the opponent's living cells; and
- maximize the AI's cell advantage over the opponent.

Strategy selection is derived from the current state hash, so the percentage
mix behaves like a distribution across turns while saved games, tests, and
AI-vs-AI experiments remain exactly reproducible. Equal scores use the
row-major first coordinate.

For repeated experiments, Black and White are configured as separate
`OneStepGreedyAgent` instances. A non-negative trial seed can vary the choice
among equal-scoring best successors while preserving the objective selected
for that turn. The same configuration and seeds always reproduce the same
games; omitting a seed retains the product's row-major tie-break behavior.

## Run strategy experiments

Run 20 reproducible games for each of the 16 ordered pairings among the three
pure strategies and the equal 34/33/33 mix:

```bash
cd packages/game_ai
dart pub get
dart run bin/one_step_experiment.dart --pretty
```

Add `--pure-only` to reproduce the original nine-pairing pure-strategy matrix.

Run one specific pairing and include each trial's seeds and outcome:

```bash
dart run bin/one_step_experiment.dart \
  --black-strategy=max-self \
  --white-strategy=min-theirs \
  --games-per-matchup=50 \
  --include-trials \
  --pretty
```

The profile names are `max-self`, `min-theirs`, `max-difference`, and `mixed`.
Win percentages use completed games as the denominator. Experiments default
to the official 100-ply population limit so both colors receive the same
number of turns.

## Optimize strategy mixtures

Run the offline adaptive optimizer and retain its complete reproducible data:

```bash
dart run bin/one_step_optimize.dart \
  --output=../../docs/experiments/one-step-mixture-optimization-data.json \
  --pretty
```

The optimizer maintains separate Black and White strategy leagues. It solves
their restricted zero-sum payoff matrix, then searches for each color's best
response on progressively finer 10%, 5%, 2%, and 1% grids. Each resolution
uses uncertainty-aware successive halving, while deterministic global probes
continue to sample unexplored regions. Newly discovered responses expand the
restricted game before the next iteration.

The final recommendations are selected by worst-case payoff within the
discovered league. They are evaluated against each other and against all four
baseline profiles using unseen seeds. The JSON output includes every candidate
score, equilibrium, payoff matrix, holdout game outcome, bootstrap confidence
interval, and estimated exploitability needed to reproduce or inspect the
result.

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
