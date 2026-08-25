# One-step strategy baseline

Date: 2026-08-24

## Method

This preliminary headless experiment ran all nine ordered pairings of the three
pure one-step strategies. Each pairing used 20 games and the standard 100-ply
population limit, for 180 games total.

Every AI assigned 100% to its named objective and 0% to the other two. The game
engine and objective evaluation remained deterministic. Trial seeds 0 through
39 varied only the selection among distinct equal-scoring best successor
states: Black used the even seed and White used the following odd seed. This
creates reproducible game variation without allowing either agent to choose a
lower-scoring move.

```bash
cd packages/game_ai
dart run bin/one_step_experiment.dart \
  --pure-only \
  --games-per-matchup=20 \
  --max-plies=100 \
  --base-seed=0 \
  --pretty
```

## Results

### Black win-rate matrix

Rows are Black's pure strategy and columns are White's pure strategy. Each cell
is Black's win rate across 20 trials; consult the detailed table for White wins
and draws.

| ID | Black \ White | Max own cells | Min their cells | Max own − theirs |
| --- | --- | ---: | ---: | ---: |
| W1 | Max own cells | 55% | 40% | 5% |
| W2 | Min their cells | 40% | 45% | 45% |
| W3 | Max own − theirs | 80% | 85% | 55% |

### Detailed results

| ID | Black strategy | White strategy | Black wins | White wins | Draws | Avg. plies |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| M1 | Max own cells | Max own cells | 11 (55%) | 9 (45%) | 0 | 95.45 |
| M2 | Max own cells | Min their cells | 8 (40%) | 12 (60%) | 0 | 23.65 |
| M3 | Max own cells | Max own − theirs | 1 (5%) | 18 (90%) | 1 (5%) | 100.00 |
| M4 | Min their cells | Max own cells | 8 (40%) | 12 (60%) | 0 | 18.15 |
| M5 | Min their cells | Min their cells | 9 (45%) | 10 (50%) | 1 (5%) | 6.30 |
| M6 | Min their cells | Max own − theirs | 9 (45%) | 10 (50%) | 1 (5%) | 13.20 |
| M7 | Max own − theirs | Max own cells | 16 (80%) | 4 (20%) | 0 | 72.95 |
| M8 | Max own − theirs | Min their cells | 17 (85%) | 3 (15%) | 0 | 8.45 |
| M9 | Max own − theirs | Max own − theirs | 11 (55%) | 9 (45%) | 0 | 41.05 |

Across all opponents, **Max own − theirs** won 44 of 60 games as Black and 37
of 60 as White. Across the complete matrix, Black won 90 games, White won 87,
and 3 were draws.

## Equal-mix extension

The experiment was extended with an **Equal mix** profile that assigns 34% to
Max own cells, 33% to Min their cells, and 33% to Max own − theirs. The extra
percentage goes to the first objective because the configuration uses whole
percentages that must total 100.

All 16 ordered pairings used 20 games under the same settings, for 320 games
total. This is the default experiment matrix:

```bash
cd packages/game_ai
dart run bin/one_step_experiment.dart \
  --games-per-matchup=20 \
  --max-plies=100 \
  --base-seed=0 \
  --pretty
```

### Four-profile Black win-rate matrix

| ID | Black \ White | Max own cells | Min their cells | Max own − theirs | Equal mix |
| --- | --- | ---: | ---: | ---: | ---: |
| X1 | Max own cells | 55% | 40% | 5% | 35% |
| X2 | Min their cells | 40% | 45% | 45% | 65% |
| X3 | Max own − theirs | 80% | 85% | 55% | 60% |
| X4 | Equal mix | 55% | 80% | 20% | 65% |

### Equal-mix matchup details

The original nine pure pairings are unchanged and appear above. These are the
seven new pairings involving Equal mix.

| ID | Black profile | White profile | Black wins | White wins | Draws | Avg. plies |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| E1 | Max own cells | Equal mix | 7 (35%) | 13 (65%) | 0 | 83.55 |
| E2 | Min their cells | Equal mix | 13 (65%) | 7 (35%) | 0 | 10.25 |
| E3 | Max own − theirs | Equal mix | 12 (60%) | 8 (40%) | 0 | 33.60 |
| E4 | Equal mix | Max own cells | 11 (55%) | 9 (45%) | 0 | 55.10 |
| E5 | Equal mix | Min their cells | 16 (80%) | 4 (20%) | 0 | 8.65 |
| E6 | Equal mix | Max own − theirs | 4 (20%) | 16 (80%) | 0 | 30.45 |
| E7 | Equal mix | Equal mix | 13 (65%) | 7 (35%) | 0 | 20.65 |

Across all four opponents, Equal mix won 44 of 80 games as Black and 35 of 80
as White. Max own − theirs remained strongest, winning 56 of 80 as Black and
53 of 80 as White. Across the full matrix, Black won 166 games, White won 151,
and 3 were draws.

## Initial interpretation

- Max own − theirs is the strongest initial pure strategy on either color.
- Equal mix is competitive with Max own cells and Min their cells, but loses
  to Max own − theirs on both color assignments in this run.
- Min their cells produces especially short, tactical games, including a
  6.3-ply average when both sides use it.
- Max own cells versus Max own − theirs usually reaches the turn limit, while
  Max own cells loses heavily in that pairing on both color assignments.
- Twenty trials per pairing are enough to expose large differences but not to
  estimate close matchups precisely. The next run should increase the trial
  count and report confidence intervals before treating small gaps as real.
