# Four-strategy elimination tournament to 1,000,000 plies

Date: 2026-08-28

## Method

The tournament ran all 16 ordered Black/White pairings of these strategies:

1. 1-step Max Self
2. 1-step Min Theirs
3. 1-step Max Difference
4. 2-step Max Difference

Each cell used 10 games under elimination-only rules, for 160 games total. The
same tie-break seed pairs, 0/1 through 18/19, were reused in every cell as
common random numbers. Active games would be right-censored at 1,000,000 plies.
The runner checkpointed every completed game and used eight parallel workers.

```bash
cd packages/game_ai
dart run bin/four_strategy_elimination_tournament.dart \
  --games-per-cell=10 \
  --safety-max-plies=1000000 \
  --base-seed=0 \
  --concurrency=8 \
  --progress-every=1000 \
  --output=../../docs/experiments/four-strategy-elimination-1m-data.json \
  --resume \
  --pretty
```

The run reproduced the previously recorded Max Self trial 0 result and final
state hash exactly: Black won at ply 14,303.

## Black win-rate matrix

Rows are Black and columns are White. Percentages use all 10 games in each
ordered cell.

| ID | Black \ White | 1-step Max Self | 1-step Min Theirs | 1-step Max Diff | 2-step Max Diff |
| --- | --- | ---: | ---: | ---: | ---: |
| W1 | 1-step Max Self | 50% | 70% | 40% | 0% |
| W2 | 1-step Min Theirs | 50% | 80% | 10% | 0% |
| W3 | 1-step Max Diff | 80% | 90% | 40% | 10% |
| W4 | 2-step Max Diff | 100% | 100% | 100% | 40% |

Two games ended in mutual extinction: Min Theirs as Black against 1-step Max
Difference, and 2-step Max Difference self-play. All other games ended with a
winner.

## Color-combined head-to-head results

Each row combines the two color assignments, for 20 games per strategy pair.
Records are first-strategy wins, second-strategy wins, and draws.

| ID | First strategy | Second strategy | Record |
| --- | --- | --- | ---: |
| H1 | 1-step Max Self | 1-step Min Theirs | 12–8–0 |
| H2 | 1-step Max Self | 1-step Max Difference | 6–14–0 |
| H3 | 1-step Max Self | 2-step Max Difference | 0–20–0 |
| H4 | 1-step Min Theirs | 1-step Max Difference | 2–17–1 |
| H5 | 1-step Min Theirs | 2-step Max Difference | 0–20–0 |
| H6 | 1-step Max Difference | 2-step Max Difference | 1–19–0 |

Across only cross-strategy games, 2-step Max Difference went **59–1**, 1-step
Max Difference went **32–27–1**, Max Self went **18–42**, and Min Theirs went
**10–49–1**.

## Completion

| ID | Metric | Result |
| --- | --- | ---: |
| R1 | Games | 160 |
| R2 | Games reaching 1,000,000 plies | 0 |
| R3 | Black wins | 86 |
| R4 | White wins | 72 |
| R5 | Mutual-extinction draws | 2 |
| R6 | Longest game | 119,940 plies |
| R7 | Mean game length | 2,486.29 plies |
| R8 | Wall time | 2,170.903 seconds |

The longest game was Max Self self-play trial 3; White won at ply 119,940.
Thus every game in this tournament finished well before the safety horizon,
although this finite sample does not prove that every possible seeded game must
finish.

Complete per-cell aggregates, seeds, outcomes, populations, and hashes are in
the [raw JSON data](./four-strategy-elimination-1m-data.json).
