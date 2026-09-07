# Local AI feature design

## Scope

The product supports two established local AI levels and one experimental level:

1. **AI level 1** maximizes its own cells minus the opponent's cells after its
   move and the resulting evolution.
2. **AI level 2** searches one move further. It chooses the first move whose
   worst legal opponent reply leaves the highest score.
3. **AI level 2.9** completes at least three plies, then iteratively deepens while
   its soft thinking budget permits. It remains experimental; reaching a deeper
   search does not automatically promote it to level 3.

All three prioritize terminal outcomes: wins score +401, losses -401, and draws
0 from the searching player's perspective. Active positions use own-minus-
opponent population (bounded by the 400-cell board). These outcome scores apply
to every supported victory rule, not only elimination. Population diagnostics
remain raw counts, distinct from the decision's utility score.

The app, the headless AI package, and offline experiments all use the shared
deterministic `game_engine`. The AI package has no Flutter, product-service,
network, or persistence dependency. L1/L2 and the game engine remain clock-free;
L2.9 uses a local stopwatch for its optional search budget.

The former Max own cells, Min their cells, percentage-mixture, adaptive
optimizer, and representative-tournament APIs are no longer supported.
Completed reports under `docs/experiments` remain as historical research.

## AI level 1

`OneStepMaxDifferenceAgent` applies every legal move through the canonical
engine. Moves that produce equal successor states are grouped and evaluated
once. The agent chooses the unique successor with the largest
terminal-aware score and uses the first row-major coordinate by
default when scores tie.

## AI level 2

`TwoStepMaxDifferenceAgent` evaluates every unique first-move successor against
every legal opponent reply. The first move receives the smallest terminal-aware
score produced by any reply. The agent selects the move with the largest
such worst-case value, making this a two-ply maximin search.

A first move that ends the game is evaluated immediately because it has no
opponent reply. Seeded SHA-256 tie-breaking is available for reproducible
headless trials and only varies the choice among equal best successors.

Move ordering examines promising candidates first. An opponent branch can stop
once it proves its first move strictly worse than the incumbent; equality is
kept to preserve all tied best moves.

## Experimental AI level 2.9

`IterativeDeepeningAgent` runs complete searches at depths 1, 2, 3, then 4 and
higher. Default minimum depth is 3, maximum depth is 64, and the soft total
thinking budget is one second. The minimum completed depth takes precedence
over that budget, so a complex position can take longer than one second.
Cancellation, unlike the time budget, can interrupt the minimum-depth search.
A proven win/loss can stop deepening once the minimum depth is complete.

Only a fully completed root iteration replaces the chosen move. Timeout during
depth 4 therefore returns the completed depth-3 decision. `maxNodes` supplies an
optional deterministic work budget for headless experiments; both budgets are
soft until minimum depth completes. Decision JSON records completed/attempted
depth, score, visited nodes, cache hits, cutoffs, elapsed time and exhaustion.

Search uses alpha-beta pruning, exact successor deduplication and a per-decision
transposition table capped at 10,000 entries. Bound entries are not treated as
exact evaluations. Keys include board, side, remaining search depth and, for
turn-limit games, remaining game plies. Repetition is not declared a draw.
No fixed-width beam removes otherwise legal successor positions.

The canonical engine's `searchSuccessors` computes the no-placement evolution
once and patches each move's affected 3×3 neighborhood. Exact change signatures
deduplicate successors before allocating boards. The optimized and ordinary
paths share the cell rule and outcome evaluator; differential tests compare
them across all legal moves on varied boards. A distant placement that dies
immediately retains its row-major representative.

The app uses `chooseMoveAsync`, which cooperatively yields in roughly 8 ms work
slices on native and web. A thinking indicator disables duplicate steps;
restart, deletion and controller disposal cancel pending work. A stale result
cannot overwrite a replacement game. The synchronous `chooseMove` API remains
available for offline experiments.

## Product configuration

Local setup supports human vs human, player vs AI with either human color, and
AI vs AI. Player vs AI has one level selector. AI vs AI has independent Black
and White selectors for all three levels in either color order. The UI displays
only opaque level names, never strategy or search-depth explanations.

- In player vs AI, the AI responds exactly once after a confirmed human move.
  If the AI is Black, it makes exactly one opening move when the match is
  created or restarted.
- In AI vs AI, the board is read-only and no turn runs automatically. Each
  press of **Next step** computes, saves, and displays exactly one AI move.

## Persistence and compatibility

Each color's persisted participant type is `human`, `aiLevel1`, `aiLevel2`, or
`aiLevel29`.
Saved participant type `ai` from the previous release maps to `aiLevel1`.
Obsolete strategy percentages in an old save are ignored and are not written
back. Saves that predate participant fields still load as human vs human.

## Historical experiments

Reports recorded before terminal utility V1 used raw population difference even
at terminal states. They are preserved unchanged and are not measurements of
the corrected agents. New output identifies the evaluator version, and the
resumable tournament rejects checkpoints from the old scoring policy.

Run `dart run bin/search_benchmark.dart` in `packages/game_ai` for a small local
move-latency/depth smoke benchmark. It is not a win-rate or graduation test.
