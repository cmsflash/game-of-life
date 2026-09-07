# game_ai

Local AI levels 1, 2 and experimental 2.9 for Life Duel. This package imports
`game_engine` directly and has no Flutter, network or persistence dependency,
so it can also be used for headless offline experiments.

All supported agents score a win +401, loss -401, draw 0, and an active position
by own-minus-opponent population. This terminal utility overrides population
size for every supported victory rule. Raw population diagnostics remain
separate from score fields.

## AI level 1

`OneStepMaxDifferenceAgent` applies every legal move with the canonical engine,
groups moves that produce the same successor state, and chooses the successor
with the highest terminal-aware score.

## AI level 2

`TwoStepMaxDifferenceAgent` examines every unique first-move successor and every
legal opponent reply (with exact branch pruning). It scores each first move by
the smallest terminal-aware score an opponent reply can leave, then chooses the
move with the largest worst-case score.

Both agents use a deterministic row-major tie break by default. A non-negative
tie-break seed can select reproducibly among equally good successors without
ever selecting a lower-scoring move.

## Experimental AI level 2.9

`IterativeDeepeningAgent` completes three plies by default, then deepens within
a one-second soft total budget. It returns the last fully completed iteration,
never a partially searched root. The minimum three plies can exceed the time
budget. Optional `minDepth`, `maxDepth` (at most 64), `timeBudget`, `maxNodes` and
`tieBreakSeed` support experiments. Fixed depth or node budgets with a generous
time budget are reproducible; time-budgeted depth can vary by device/load.

The engine provides exact incremental, deduplicated successors. Alpha-beta
search orders moves and caches depth-qualified exact values/bounds without
introducing a repetition-draw rule. Terminal-aware cell difference remains the
leaf evaluator; there is no beam cutoff or learned policy.

Use synchronous `chooseMove` in headless runners, or
`await agent.chooseMoveAsync(state, isCancelled: () => cancelled)` for a
responsive UI including web. Cancellation throws `SearchCancelledException`.
Decisions expose completed/attempted depth, utility, work and latency counters.
The product name stays **AI level 2.9** until separately evaluated and promoted.

```bash
dart run bin/search_benchmark.dart
```

This runs a bounded move benchmark on four positions, not a tournament.

## Headless matches

`AiMatchRunner` runs any two `GameAgent` implementations against each other.
Callers provide the rules or initial state and a safety ply limit. This keeps
offline experiments on exactly the same rules implementation used by the app.

Historical reports predate terminal utility V1 and do not describe the corrected
L1/L2 policy. Use a new output path for new runs; old tournament checkpoints
cannot be resumed into the new scoring policy.

Run seeded AI-level-1 self-play under elimination-only rules, retaining every
trial and reporting any game still active at the safety horizon:

```bash
dart run bin/max_difference_elimination_experiment.dart \
  --games=100 \
  --safety-max-plies=1000 \
  --concurrency=100 \
  --output=../../docs/experiments/one-step-max-difference-elimination-data.json \
  --pretty
```

For the historical one-step Max Self strategy, use the experiment-only runner:

```bash
dart run bin/max_self_elimination_experiment.dart \
  --games=100 \
  --safety-max-plies=1000 \
  --concurrency=100 \
  --output=../../docs/experiments/one-step-max-self-elimination-data.json \
  --pretty
```

This does not restore Max Self as an app AI level or a supported package agent.
Exact trial IDs from a prior result can be replayed with
`--trial-ids=0,19,30`.

The recorded 10,000-ply follow-up uses:

```bash
dart run bin/max_self_elimination_experiment.dart \
  --trial-ids=0,19,30,48,52,64,67,72,79,85 \
  --safety-max-plies=10000 \
  --concurrency=10 \
  --output=../../docs/experiments/one-step-max-self-elimination-10k-sample-data.json \
  --pretty
```

The single-game follow-ups use `--trial-ids=0 --safety-max-plies=100000` and
`--trial-ids=19 --safety-max-plies=100000`.

The remaining six sampled trials use:

```bash
dart run bin/max_self_elimination_experiment.dart \
  --trial-ids=48,52,64,67,72,85 \
  --safety-max-plies=100000 \
  --concurrency=6 \
  --output=../../docs/experiments/one-step-max-self-elimination-100k-remainder-data.json \
  --pretty
```

The final active sampled trial was replayed toward a 1,000,000-ply horizon
with exact progress checkpoints:

```bash
dart run bin/max_self_elimination_experiment.dart \
  --trial-ids=52 \
  --safety-max-plies=1000000 \
  --concurrency=1 \
  --progress-every=10000 \
  --output=../../docs/experiments/one-step-max-self-elimination-1m-trial-52-data.json \
  --pretty
```

Run the ordered 4×4 elimination tournament for the historical Max Self and Min
Theirs strategies plus the two supported Max Difference levels:

```bash
dart run bin/four_strategy_elimination_tournament.dart \
  --games-per-cell=10 \
  --safety-max-plies=1000000 \
  --concurrency=8 \
  --progress-every=1000 \
  --output=../../docs/experiments/four-strategy-terminal-utility-data.json \
  --resume \
  --pretty
```

The output is atomically checkpointed after every game and can be resumed with
the same configuration.

## Test

```bash
dart test
dart analyze --fatal-infos
```
