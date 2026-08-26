# One-step mixture optimization

Date: 2026-08-25

> **Historical report.** Percentage mixtures and the adaptive optimizer were
> retired on 2026-08-26. The supported product AI levels now use Max difference
> exclusively. These results and their raw data remain as the record of the
> completed research run.

## Objective

This offline experiment searched for separate Black and White probability
vectors over the three one-step objectives. Game utility was `+1` for a Black
win, `0` for a draw, and `-1` for a White win. The optimization retained the
non-transitive payoff matrix rather than reducing strategies to Elo.

The primary target was a robust strategy: Black maximizes payoff against the
White equilibrium, while White minimizes Black's payoff against the Black
equilibrium. The final report includes both the equilibrium meta-strategy and
one robust single profile for each color.

## Method

The restricted game began with Max own cells, Min their cells, Max own −
theirs, and Equal mix. Each restricted-game pairing used 100 games, and 50,000
deterministic fictitious-play iterations approximated its zero-sum equilibrium.

Each color then searched for a best response to the opponent equilibrium:

1. Evaluate all 66 mixtures on the 10% simplex grid, plus off-grid league
   profiles.
2. Give every candidate 12 common-seed games.
3. Give the 20 strongest or most uncertain candidates 40 games.
4. Give five finalists 200 games and rank them by observed mean utility.
5. Refine around those finalists at 5%, 2%, and 1%, retaining eight
   deterministic global probes at every refinement.
6. Add the discovered response to its color's league and repeat the process
   for two double-oracle iterations.
7. Run a complete external best-response audit with disjoint training seeds.
8. Validate the recommended profiles in 500-game matchups using unseen seeds
   beginning at 1,010,000 and 10,000 deterministic bootstrap samples.

The run completed **69,988 games**: 62,388 adaptive-search games, 3,600
restricted-game games, and 4,000 holdout games. The complete candidate scores,
payoff matrices, equilibria, configuration, and holdout outcomes are in the
[raw JSON data](./one-step-mixture-optimization-data.json).

```bash
cd packages/game_ai
dart run bin/one_step_optimize.dart \
  --output=../../docs/experiments/one-step-mixture-optimization-data.json \
  --pretty
```

## Recommended single profiles

These are the maximin/minimax single profiles within the final discovered
league. Percentages are ordered as Max own / Min theirs / Max difference.

| ID | Color | Recommended profile | Selection criterion |
| --- | --- | --- | --- |
| R1 | Black | **0/18/82** | Highest worst-case training payoff among discovered Black profiles |
| R2 | White | **0/0/100** | Lowest worst-case Black training payoff among discovered White profiles |

The single recommendations are not a pure-strategy saddle point. In their
500-game holdout matchup, Black 0/18/82 won 207 games, White 0/0/100 won 290,
and 3 were draws. Black utility was `-0.166`, with a 95% bootstrap interval of
`[-0.252, -0.080]`.

## Restricted-game equilibrium

The final equilibrium was almost fair at the meta-strategy level, with Black
utility `-0.0082`. Its supported profiles were:

| ID | Color | Internal mixture | Equilibrium weight |
| --- | --- | --- | ---: |
| Q1 | Black | 0/18/82 | 36.388% |
| Q2 | Black | 2/10/88 | 63.604% |
| Q3 | White | 0/0/100 | 45.428% |
| Q4 | White | 0/8/92 | 54.572% |

The restricted matrix's internal exploitability was `0.0000148`, but this only
measures strategies already in the matrix. The external audit found a wider
gap:

| ID | Audit | Best discovered response | Games | Black wins | White wins | Draws | Black utility |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| A1 | Black response to White equilibrium | 4/21/75 | 200 | 91 | 108 | 1 | -0.085 |
| A2 | White response to Black equilibrium | 4/5/91 | 200 | 79 | 119 | 2 | -0.200 |

The difference between those externally searched bounds is **0.115 utility**.
It is an exploitability estimate, not an 11.5-point win-rate estimate, and it
shows that two league expansions did not establish convergence over the full
mixture space.

## Holdout performance

### Recommended Black against baseline Whites

| ID | White profile | Black wins | White wins | Draws | Black utility | 95% utility interval |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| B1 | Max own cells | 347 (69.4%) | 144 (28.8%) | 9 (1.8%) | 0.406 | [0.326, 0.484] |
| B2 | Min their cells | 402 (80.4%) | 92 (18.4%) | 6 (1.2%) | 0.620 | [0.550, 0.686] |
| B3 | Max own − theirs | 207 (41.4%) | 290 (58.0%) | 3 (0.6%) | -0.166 | [-0.252, -0.080] |
| B4 | Equal mix | 344 (68.8%) | 153 (30.6%) | 3 (0.6%) | 0.382 | [0.300, 0.464] |

### Baseline Blacks against recommended White

| ID | Black profile | Black wins | White wins | Draws | Black utility | 95% utility interval |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| W1 | Max own cells | 70 (14.0%) | 424 (84.8%) | 6 (1.2%) | -0.708 | [-0.768, -0.648] |
| W2 | Min their cells | 113 (22.6%) | 385 (77.0%) | 2 (0.4%) | -0.544 | [-0.618, -0.470] |
| W3 | Max own − theirs | 222 (44.4%) | 273 (54.6%) | 5 (1.0%) | -0.102 | [-0.190, -0.014] |
| W4 | Equal mix | 120 (24.0%) | 377 (75.4%) | 3 (0.6%) | -0.514 | [-0.588, -0.442] |

## Interpretation

- White's strongest robust single profile remains pure Max difference. It beat
  every baseline Black profile in holdout, including pure Max difference.
- Black's 0/18/82 candidate replaces a small amount of Max difference with Min
  theirs and had the best training worst case across the discovered White
  league. It decisively beat the other three baselines in holdout but lost to
  White's Max difference profile.
- The near-zero restricted-game value depends on randomizing over two internal
  mixtures for each color. Selecting one internal mixture per color loses that
  additional meta-strategy protection.
- The 0.115 external gap and the difference between training and holdout mean
  these results are strong candidates, not proof of a global optimum. More
  oracle expansions and a larger restricted-matrix sample would be required
  before claiming practical convergence.
