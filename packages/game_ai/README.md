# game_ai

The two supported Max Difference AI levels for Life Duel. This package imports
`game_engine` directly and has no Flutter, network, persistence, or clock
dependency, so it can also be used for headless offline experiments.

## AI level 1

`OneStepMaxDifferenceAgent` applies every legal move with the canonical engine,
groups moves that produce the same successor state, and chooses the successor
with the largest own-minus-opponent living-cell count.

## AI level 2

`TwoStepMaxDifferenceAgent` examines every unique first-move successor and every
legal opponent reply. It scores each first move by the smallest population
advantage an opponent reply can leave, then chooses the move with the largest
worst-case score.

Both agents use a deterministic row-major tie break by default. A non-negative
tie-break seed can select reproducibly among equally good successors without
ever selecting a lower-scoring move.

## Headless matches

`AiMatchRunner` runs any two `GameAgent` implementations against each other.
Callers provide the rules or initial state and a safety ply limit. This keeps
offline experiments on exactly the same rules implementation used by the app.

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

## Test

```bash
dart test
dart analyze --fatal-infos
```
