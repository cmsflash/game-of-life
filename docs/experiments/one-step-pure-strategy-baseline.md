# One-step pure-strategy baseline

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
  --games-per-matchup=20 \
  --max-plies=100 \
  --base-seed=0 \
  --pretty
```

## Results

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

## Initial interpretation

- Max own − theirs is the strongest initial pure strategy on either color.
- Min their cells produces especially short, tactical games, including a
  6.3-ply average when both sides use it.
- Max own cells versus Max own − theirs usually reaches the turn limit, while
  Max own cells loses heavily in that pairing on both color assignments.
- Twenty trials per pairing are enough to expose large differences but not to
  estimate close matchups precisely. The next run should increase the trial
  count and report confidence intervals before treating small gaps as real.
