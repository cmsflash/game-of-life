# One-step Max Self elimination: trial 0 to 100,000 plies

Date: 2026-08-27

## Method

This follow-up selected original trial 0 from the eight games still active in
the 10,000-ply sample. The runner deterministically replayed its original
Black/White tie-break seeds 0/1 under elimination-only rules, with a 100,000-ply
safety horizon.

```bash
cd packages/game_ai
dart run bin/max_self_elimination_experiment.dart \
  --trial-ids=0 \
  --safety-max-plies=100000 \
  --base-seed=0 \
  --concurrency=1 \
  --output=../../docs/experiments/one-step-max-self-elimination-100k-trial-0-data.json \
  --pretty
```

## Result

| ID | Metric | Result |
| --- | --- | ---: |
| R1 | Trial | 0 |
| R2 | Seeds (Black/White) | 0/1 |
| R3 | Terminal ply | 14,303 |
| R4 | Winner | Black |
| R5 | Terminal population | Black 11 / White 0 |
| R6 | Reached 100,000-ply cutoff | No |
| R7 | Wall time | 209.542 seconds |

The game that was active at both 1,000 and 10,000 plies naturally ended by
elimination at ply 14,303. This shows that surviving to 10,000 plies does not
by itself imply an infinite trajectory.

Complete terminal hashes are in the
[raw JSON data](./one-step-max-self-elimination-100k-trial-0-data.json).
