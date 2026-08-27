# One-step Max Self elimination self-play

Date: 2026-08-27

## Method

This experiment reran the elimination-only self-play benchmark with both
players using the historical one-step Max Self strategy. On every turn, each
player chose a successor with the largest number of its own living cells,
without considering the opponent population except through the game evolution.

- The victory rule was elimination only.
- Trials used Black/White tie-break seed pairs 0/1 through 198/199.
- Seeds varied only the selection among equally scoring best successors.
- All 100 games ran in parallel workers; turns within each game remained
  sequential.
- A game still active at 1,000 plies was reported as truncated, with no winner.
- The runner is experiment-only and does not restore Max Self in the app.

```bash
cd packages/game_ai
dart run bin/max_self_elimination_experiment.dart \
  --games=100 \
  --safety-max-plies=1000 \
  --base-seed=0 \
  --concurrency=100 \
  --output=../../docs/experiments/one-step-max-self-elimination-data.json \
  --pretty
```

## Results

| ID | Metric | Result |
| --- | --- | ---: |
| R1 | Games | 100 |
| R2 | Eliminations by 1,000 plies | 1 |
| R3 | Still active at 1,000 plies | 99 |
| R4 | Black wins | 1 |
| R5 | White wins | 0 |
| R6 | Earliest elimination | 385 plies |
| R7 | Games active after 100 plies | 100 |
| R8 | Games active after 300 plies | 100 |
| R9 | Games active after 500 plies | 99 |
| R10 | Wall time with 100 workers | 414.084 seconds |

The sole elimination was trial 89, using Black/White tie-break seeds 178/179.
Black eliminated White at ply 385 with 47 Black cells remaining.

Because 99 observations are right-censored at 1,000 plies, their true game
lengths are unknown. The observed median and 95th percentile are therefore at
least 1,000 plies; reporting the capped mean of 993.85 as an ordinary duration
would be misleading.

## Comparison with Max Difference

| ID | Pairing | Eliminated by 1,000 | Still active | Maximum observed plies |
| --- | --- | ---: | ---: | ---: |
| C1 | Max Difference vs. Max Difference | 100 | 0 | 394 |
| C2 | Max Self vs. Max Self | 1 | 99 | 1,000 (censored) |

The contrast is decisive for these seeds: maximizing only one's own population
does not generally drive the sampled games toward elimination. This experiment
does not prove that the 99 active games continue forever; it establishes only
that they did not finish within the 1,000-ply horizon.

A sequential rerun of trials 0 and 1 reproduced their populations and final
state hashes exactly. Complete seeds, outcomes, cutoff populations, plies, and
hashes are in the [raw JSON data](./one-step-max-self-elimination-data.json).

## Follow-up

A reproducible random sample of 10 unfinished trials was extended to 10,000
plies. Eight remained active; see the
[10,000-ply sample report](./one-step-max-self-elimination-10k-sample.md).
