# One-step Max Difference elimination self-play

Date: 2026-08-27

## Historical experiment audit

Every earlier recorded bulk AI experiment used the 100-ply population victory
rule, not elimination-only play:

| ID | Experiment | Games | Terminal rule |
| --- | --- | ---: | --- |
| H1 | One-step pure strategies plus Equal mix | 320 | Population winner at 100 plies |
| H2 | Adaptive one-step mixture optimization | 69,988 | Population winner at 100 plies |
| H3 | Two-step versus representative one-step AIs | 800 | Population winner at 100 plies |

The original generic greedy command also ran only one game at a time and used
the same 100-ply population rule. Therefore none of those results established
that games naturally finish by elimination.

## Method

This experiment ran AI level 1—one-step Max Difference—against itself in 100
independent games. Each player maximized its own living cells minus the
opponent's living cells after one move and evolution.

- The victory rule was elimination only.
- Trials used Black/White tie-break seed pairs 0/1 through 198/199.
- Seeds varied only the selection among equally scoring best successors.
- All 100 games ran in parallel workers; turns within each game remained
  sequential.
- A game still active at 1,000 plies was to be reported as truncated rather
  than assigned an artificial winner.

```bash
cd packages/game_ai
dart run bin/max_difference_elimination_experiment.dart \
  --games=100 \
  --safety-max-plies=1000 \
  --base-seed=0 \
  --concurrency=100 \
  --output=../../docs/experiments/one-step-max-difference-elimination-data.json \
  --pretty
```

## Results

| ID | Metric | Result |
| --- | --- | ---: |
| R1 | Games | 100 |
| R2 | Eliminations | 100 |
| R3 | Still active at 1,000 plies | 0 |
| R4 | Black wins | 42 |
| R5 | White wins | 58 |
| R6 | Draws | 0 |
| R7 | Minimum plies | 4 |
| R8 | Median plies | 41.5 |
| R9 | Mean plies | 67.57 |
| R10 | 95th-percentile plies | 204 |
| R11 | Maximum plies | 394 |
| R12 | Wall time with 100 workers | 22.911 seconds |

Twenty-three games continued beyond the old 100-ply cutoff, seven continued
beyond 200 plies, and two continued beyond 300 plies. The longest game used
seed pair 134/135 and ended with White eliminating Black at ply 394.

## Interpretation

All 100 sampled Max-Difference self-play games naturally ended by elimination
within 1,000 plies. This is meaningful evidence that this pairing tends to
finish, but it is not a proof that every seed or every possible position must
finish. The previous 100-ply experiments would have prematurely assigned a
population result to 23 of these games.

The complete seeds, outcomes, populations, plies, and final hashes are in the
[raw JSON data](./one-step-max-difference-elimination-data.json).
