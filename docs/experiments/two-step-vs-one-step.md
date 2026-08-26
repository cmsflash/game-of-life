# Two-step Max difference versus representative one-step AIs

Date: 2026-08-26

> **Historical report.** The representative one-step objectives and this
> experiment command were retired after this run. The product now exposes the
> one-step and two-step Max difference agents as AI level 1 and AI level 2.

## Objective

This headless experiment introduced a depth-two Max difference agent and
measured it as both Black and White against four representative one-step
profiles: Max own cells, Min their cells, Max own minus theirs, and Equal mix.

“Two-step” means two plies: the AI's move followed by one opponent reply. For
each unique first-move successor, the agent applies every legal opponent reply
and records the smallest resulting own-minus-theirs population advantage. It
chooses the first move with the largest such worst-case score. Therefore the
search is maximin and does not assume that the actual opponent will use a
particular one-step objective.

## Method

- 100 games were run for each color/profile pairing, for 800 games total.
- Games used the standard 100-ply population victory rule.
- Black/White tie-break seed pairs began at 2,000,000 and were reused across
  the eight matchups as common random numbers.
- Seeded SHA-256 tie-breaking varied equal best successors without selecting a
  lower-scoring move.
- The eight matchups ran in parallel isolates. The complete run took 5 hours,
  45 minutes, and 59 seconds because reply trees become much wider in later
  board states.
- Reported 95% intervals are Wilson intervals for the two-step win rate.

```bash
cd packages/game_ai
dart run bin/two_step_experiment.dart \
  --games-per-matchup=100 \
  --max-plies=100 \
  --base-seed=2000000 \
  --concurrency=8 \
  --include-trials \
  --output=../../docs/experiments/two-step-vs-one-step-data.json \
  --pretty
```

## Results

Every row is reported from the two-step agent's perspective.

| ID | Two-step color | One-step opponent | Two-step wins | One-step wins | Draws | Two-step win rate | 95% interval | Avg. plies |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- | ---: |
| R1 | Black | Max own cells | 98 | 2 | 0 | 98% | [93.0%, 99.4%] | 76.60 |
| R2 | White | Max own cells | 98 | 2 | 0 | 98% | [93.0%, 99.4%] | 81.58 |
| R3 | Black | Min their cells | 100 | 0 | 0 | 100% | [96.3%, 100%] | 4.74 |
| R4 | White | Min their cells | 100 | 0 | 0 | 100% | [96.3%, 100%] | 5.68 |
| R5 | Black | Max own minus theirs | 99 | 1 | 0 | 99% | [94.6%, 99.8%] | 26.70 |
| R6 | White | Max own minus theirs | 99 | 1 | 0 | 99% | [94.6%, 99.8%] | 21.18 |
| R7 | Black | Equal mix | 100 | 0 | 0 | 100% | [96.3%, 100%] | 18.55 |
| R8 | White | Equal mix | 100 | 0 | 0 | 100% | [96.3%, 100%] | 16.47 |

Overall, the two-step agent won **794 of 800 games (99.25%)**. The aggregate
95% Wilson interval is **[98.37%, 99.66%]**, and its mean game utility was
`+0.985` from its own perspective. There were no draws or truncated games.

## Interpretation

- The extra reply ply produced a decisive improvement against all four
  representative one-step policies in this seed cohort.
- Results were nearly color-symmetric: the two-step agent produced the same
  win count in both colors against every opponent.
- Min their cells was the weakest representative opponent and usually lost by
  elimination within six plies. Max own cells survived longest, often reaching
  the turn limit, but still won only two games in either color.
- This establishes superiority over the four named representatives, not over
  every one-step mixture. A broader mixture search would be a separate
  experiment.
- Depth-two computation is expensive with the current exhaustive engine calls.
  Larger tournaments should first add search-specific caching or incremental
  successor evaluation rather than scale this implementation blindly.

The complete seeds, outcomes, populations, plies, and final state hashes are
in [the raw JSON data](./two-step-vs-one-step-data.json).
