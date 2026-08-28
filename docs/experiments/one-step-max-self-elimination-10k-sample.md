# One-step Max Self elimination: 10,000-ply sample

Date: 2026-08-27

## Method

This follow-up sampled 10 of the 99 Max Self self-play games that were still
active at the original 1,000-ply cutoff. Python's seeded sampler selected the
following original trial IDs without replacement using selection seed
20260827: 0, 19, 30, 48, 52, 64, 67, 72, 79, and 85.

The original artifact retained seeds and hashes, but not complete board states.
The runner therefore deterministically replayed each selected trial from its
original Black/White tie-break seeds and extended the same trajectory to a
10,000-ply safety horizon. The victory rule remained elimination only.

```bash
cd packages/game_ai
dart run bin/max_self_elimination_experiment.dart \
  --trial-ids=0,19,30,48,52,64,67,72,79,85 \
  --safety-max-plies=10000 \
  --base-seed=0 \
  --concurrency=10 \
  --output=../../docs/experiments/one-step-max-self-elimination-10k-sample-data.json \
  --pretty
```

## Results

| ID | Metric | Result |
| --- | --- | ---: |
| R1 | Sampled games | 10 |
| R2 | Eliminations by 10,000 plies | 2 |
| R3 | Still active at 10,000 plies | 8 |
| R4 | Black wins | 1 |
| R5 | White wins | 1 |
| R6 | Earliest sampled elimination | 5,365 plies |
| R7 | Latest sampled elimination | 8,950 plies |
| R8 | Wall time with 10 workers | 376.753 seconds |

| ID | Original trial | Seeds (Black/White) | Result | Plies |
| --- | ---: | --- | --- | ---: |
| G1 | 0 | 0/1 | Still active | 10,000 |
| G2 | 19 | 38/39 | Still active | 10,000 |
| G3 | 30 | 60/61 | White eliminated Black | 8,950 |
| G4 | 48 | 96/97 | Still active | 10,000 |
| G5 | 52 | 104/105 | Still active | 10,000 |
| G6 | 64 | 128/129 | Still active | 10,000 |
| G7 | 67 | 134/135 | Still active | 10,000 |
| G8 | 72 | 144/145 | Still active | 10,000 |
| G9 | 79 | 158/159 | Black eliminated White | 5,365 |
| G10 | 85 | 170/171 | Still active | 10,000 |

## Interpretation

Extending the horizon changed two sampled games from unfinished to eliminated,
but 80% of the sample remained active after 10,000 plies. Max Self self-play
therefore produces games that are orders of magnitude longer than the sampled
Max Difference self-play games, all of which finished by ply 394.

The eight active observations are right-censored at 10,000 plies. This result
does not establish that they continue indefinitely. Complete cutoff
populations and final hashes are in the
[raw JSON data](./one-step-max-self-elimination-10k-sample-data.json).

## Follow-ups

| ID | Trial | 100,000-ply follow-up |
| --- | ---: | --- |
| F1 | 0 | Black eliminated White at ply 14,303 |
| F2 | 19 | White eliminated Black at ply 93,580 |

See the detailed [trial 0 report](./one-step-max-self-elimination-100k-trial-0.md)
and [trial 19 report](./one-step-max-self-elimination-100k-trial-19.md).
