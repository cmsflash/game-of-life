# Budget-controlled search comparison

Date: 2026-09-23. This is an offline experiment, not a product-level change.

## Question and policies

At a fixed exploration ceiling, is full-width search or narrower, deeper search
stronger? All policies use terminal utility V1: win +401, loss -401, draw 0,
and own-minus-opponent population for active positions.

| ID | Maximum outlook (plies) | Full-width prefix | Width afterward |
| --- | ---: | ---: | ---: |
| D1 | 1 | All | All |
| D2 | 2 | All | All |
| D3 | 3 | All | All |
| D4 | 4 | All | All |
| D5 | 5 | All | All |
| D8 | 8 | All | All |
| F1B4 | 8 | First 1 ply | 4 |
| F1B8 | 8 | First 1 ply | 8 |
| F2B4 | 8 | First 2 plies | 4 |
| F2B8 | 8 | First 2 plies | 8 |

A ply is one player's placement plus evolution. A depth-3 search therefore
looks at our move, their reply, then our next move. Full width means no beam
discards legal successor positions; exact deduplication and safe alpha-beta
pruning still apply. All policies examine every distinct root successor.
Selective search orders replies from the opponent's perspective, not ours.

All policies use the same iterative-deepening search implementation. If a
deeper iteration runs out of budget, it returns the last completed iteration.
The depth cap is not a promise that the requested depth was reached. Selective
search finding a winning line is not proof of a forced win in the full game.
Completed depth describes a completed search horizon: terminal branches end
earlier. A separate `maxVisitedPly` diagnostic records the deepest ply actually
visited across the decision, including any incomplete deeper iteration.
D1/D2 match the corresponding horizon/evaluator policies, but their seeded
tie-breaking namespace differs from the app agents. Budgeted D2 can fall back
to depth 1; any such turns must be reported.

## Work accounting

Each decision has a hard ceiling of **100,000 generated distinct successor
states**, counted across every iterative-deepening pass. This includes states
generated only for ordering, rejected beam candidates, and regenerated states.
Transposition-table hits do not regenerate states. The table is capped at
10,000 entries per decision for every policy.

This is an equal ceiling, not equal actual work: a depth-1 policy usually stops
well below the ceiling. Duplicate-detection work, sorting, hashing and other
overhead are not identical per charged successor. Report actual work and move
latency alongside results; do not call this equal wall-clock time. Local
workers run the compiled offline runner. No AWS or other cloud compute is used.

Scheduling amendment during the screen: started with six concurrent games,
then resumed from checkpoints with eighteen slots so long full-width games did
not prevent the selective variants from starting. Search is deterministic and
has no time cutoff, so this does not change moves or work ceilings. Tournament
latencies mix concurrency levels and are descriptive, not controlled speed
comparisons. The original source revision and game configuration remain intact.

Opening/ply-4/ply-8 smoke benchmarks motivated 100,000: 10,000 mostly stopped at
depth 3, whereas 100,000 allowed some full-width depth 4 and selective depth
5–6 decisions. These timing probes are not strength evidence.

## Games and stopping

Use elimination rules and the canonical centered 2×2 diagonal opening. Every
ordered pairing receives the same tie-break seed pairs. Black and White seeds
are `baseSeed + 2 * trial` and `baseSeed + 2 * trial + 1` respectively. There is
no repetition-as-draw rule and no population adjudication at a time limit.

An active game at **1,000,000 plies** is censored/unfinished, never a draw.
Save resumable states and per-move diagnostics every 25 plies and on completion.
Games still running or failing are separate from safety-cap truncations.
The source revision and normalized configuration hash identify each run.

## Predeclared stages

1. **Screen:** every challenger against D2, both colors, 2 games per ordered
   cell (36 games), base seed 6,000,000. This small sample is only a filter.
2. **Confirmation:** D1, D2, the screen's best of D3/D4/D5/D8, and its best of
   F1B4/F1B8/F2B4/F2B8. Run the complete 4×4 ordered matrix, including self-play,
   with 10 games per cell (160 games), on fresh seeds starting at 6,100,000.

Selection uses color-combined score against D2 (win 1, draw 0.5, loss 0), then
worst-color score, then lower mean actual successor count per decision, then
lexical profile ID. If a screen game is unfinished, do not silently score it
as a draw or rank incomplete estimates as final results: report the limitation
and use score bounds before choosing a follow-up.

## Reporting and interpretation

Report Black win rates with separate draws and unfinished counts, color-combined
head-to-head records, finished-game length mean/median/p90/maximum, longest-game
seeds, per-policy completed-depth distributions, and per-move work/latency.
Report finished-only length statistics as such; censoring makes them biased
downward as estimates of all-game duration. Self-play is excluded from pooled
cross-opponent strength summaries.

Ten games per ordered cell is exploratory, not definitive. Common seed pairs
and deterministic play also mean these are not an independently sampled set of
openings. Fresh confirmation seeds reduce selection overfitting but do not
establish general performance on other initial boards. Any confidence interval
is descriptive under a binomial approximation, not proof of general strength.
Do not automatically graduate a winning experimental policy to AI level 3.
