# Budgeted search: first findings

Date: 2026-09-23. **Interim: the win-rate screen is still running.** No finalist
has been selected and the fresh-seed confirmation tournament has not started.

## Implemented comparison

Ten terminal-aware policies now share one deterministic, hard-budget search
engine: full-width maximum horizons 1, 2, 3, 4, 5 and 8, plus four selective
policies that keep all successors for the first one or two plies and then
retain the best 4 or 8 candidates at each node. A ply is one player's move.

The head-to-head screen gives every decision the same 100,000-generated-
successor ceiling. Actual work can be lower; it is recorded separately.
See the [predeclared protocol](budgeted-search-protocol.md) and
[screen configuration](budgeted-search-screen-config.json).

## Identical midgame position: depth versus budget

The opening was too easy to represent the whole game. This probe replays trial
0 of D2 as Black against D3 as White, using seeds 6,000,000/6,000,001, to exactly
ply 100. Every policy then searches **the same immutable position**, with the
same tie-breaking seed 9,000,000. There is one comparison per profile/budget.

Numbers below are **completed horizons**, not attempted depth or deepest node
visited during an unfinished iteration.

| ID | Search profile | 10K ceiling | 100K ceiling | 1M ceiling |
| --- | --- | ---: | ---: | ---: |
| B1 | D1: full width, cap 1 | 1 | 1 | 1 |
| B2 | D2: full width, cap 2 | 1 | 2 | 2 |
| B3 | D3/D4/D5/D8: full width, respective caps | 1 | 2 | 3 |
| B4 | F1B4: full first ply, then width 4, cap 8 | 1 | 3 | 6 |
| B5 | F1B8: full first ply, then width 8, cap 8 | 1 | 3 | 5 |
| B6 | F2B4/F2B8: full first two plies, then width 4/8, cap 8 | 1 | 2 | 4 |

In this position, full-width depth 3 needed 140,525 generated successors.
Requesting deeper full-width search spent the entire 1M ceiling but still
returned the depth-3 move. Narrowing after the first ply instead completed
depth 5 or 6 under that same ceiling.

**This establishes a depth/work tradeoff, not a strength ranking.** Selective
search can overlook a critical reply. Deeper completed search is not itself a
win-rate result, and a single midgame position does not establish a universal
depth-versus-budget curve.

The original probe is saved in [raw results](budgeted-search-midgame-benchmark.json).
Its dirty-workspace marker includes the then-uncommitted benchmark utility;
the benchmark source has its own recorded SHA-256. A separate clean-source
recheck is saved in [confirmed raw results](budgeted-search-midgame-confirmed-benchmark.json).
Both preserve the exact position and move prefix. Timings were measured under
concurrent tournament load, so they are descriptive rather than isolated
latency measurements.

## Win rates and game lengths: not final

The D1-versus-D2 screening subset finished all four games. D2 won both Black
games (9 and 15 plies) and both White games (6 and 6 plies). Mean length was
9 plies. Four games are far too few to claim a precise population win rate.

At least one deeper-policy game has passed 1,000 plies without elimination.
Active games are unresolved, not draws or wins awarded by current population.
The long-run safety cap remains 1,000,000 plies. This finite observation cannot
establish that a game continues forever.

The timestamped [screen snapshot](budgeted-search-screen-progress.md) reports
completed outcomes, unresolved counts, game lengths, work consumption and
completed-horizon distributions. Its source checkpoints continue advancing;
it is not a continuously refreshing dashboard.

The planned next stage is a fresh-seed 4×4 matrix with 10 games per ordered
cell, using D1, D2 and the best full-width/selective screening candidates.
That selection must wait for interpretable screening outcomes; it has not
been made from unfinished games or from depth alone.

## Verification

The AI package passes 78 tests, the canonical engine passes 47, and the report
tool passes 16. These include exhaustive small-position references, strict
work ceilings, seeded continuation, checkpoint corruption rejection, terminal
win/loss scoring and censoring semantics. Two finished screening games were also
independently replayed through the canonical engine. No app UI or level naming
changed for these experiments.
