# One-step Max Self elimination: trial 52 to 1,000,000 plies

Date: 2026-08-27

## Method

Trial 52 was the only game in the 10-game sample still active at the prior
100,000-ply cutoff. It was deterministically replayed from the start with the
same Black/White tie-break seeds, 104 and 105, under elimination-only rules.
The safety horizon was raised to 1,000,000 plies.

The replay reproduced the recorded populations at both available checkpoints:
52 Black and 14 White cells at 10,000 plies, then 23 Black and 17 White cells
at 100,000 plies.

```bash
cd packages/game_ai
dart run bin/max_self_elimination_experiment.dart \
  --trial-ids=52 \
  --safety-max-plies=1000000 \
  --base-seed=0 \
  --concurrency=1 \
  --progress-every=10000 \
  --output=../../docs/experiments/one-step-max-self-elimination-1m-trial-52-data.json \
  --pretty
```

## Result

| ID | Metric | Result |
| --- | --- | ---: |
| R1 | Result | White eliminated Black |
| R2 | Elimination ply | 102,486 |
| R3 | Final Black population | 0 |
| R4 | Final White population | 32 |
| R5 | Safety horizon reached | No |
| R6 | Wall time | 1,490.142 seconds |

Trial 52 eliminated only 2,486 plies after the previous cutoff. Consequently,
all 10 sampled Max Self self-play games eventually eliminated; their observed
maximum duration was 102,486 plies. This does not prove that every possible
Max Self self-play game must finish, but there are no unfinished games left in
this sample.

Complete seeds, populations, and final hashes are in the
[raw JSON data](./one-step-max-self-elimination-1m-trial-52-data.json).
