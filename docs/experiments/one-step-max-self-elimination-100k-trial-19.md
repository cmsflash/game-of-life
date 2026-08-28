# One-step Max Self elimination: trial 19 to 100,000 plies

Date: 2026-08-27

## Method

This follow-up selected original trial 19 from the games still active in the
10,000-ply sample. The runner deterministically replayed its original
Black/White tie-break seeds 38/39 under elimination-only rules, with a
100,000-ply safety horizon.

```bash
cd packages/game_ai
dart run bin/max_self_elimination_experiment.dart \
  --trial-ids=19 \
  --safety-max-plies=100000 \
  --base-seed=0 \
  --concurrency=1 \
  --output=../../docs/experiments/one-step-max-self-elimination-100k-trial-19-data.json \
  --pretty
```

## Result

| ID | Metric | Result |
| --- | --- | ---: |
| R1 | Trial | 19 |
| R2 | Seeds (Black/White) | 38/39 |
| R3 | Terminal ply | 93,580 |
| R4 | Winner | White |
| R5 | Terminal population | Black 0 / White 65 |
| R6 | Reached 100,000-ply cutoff | No |
| R7 | Wall time | 1,206.901 seconds |

The game that remained active at both 1,000 and 10,000 plies naturally ended
by elimination at ply 93,580, only 6,420 plies before the safety cutoff. This
is the longest completed Max Self trajectory observed in these follow-ups.

Complete terminal hashes are in the
[raw JSON data](./one-step-max-self-elimination-100k-trial-19-data.json).
