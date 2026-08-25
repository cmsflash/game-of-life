# Local AI feature design

## Scope

The first product AI is a local, one-step greedy opponent. It runs entirely in
the Flutter client through `game_ai` and the shared deterministic `game_engine`.
It does not call the product API, affect ratings, or change the game rules.

Local setup supports human vs human, player vs AI with either human color, and
AI vs AI. The current product UI gives all AI players in one local match the
same three strategy percentages. The headless experiment API configures Black
and White independently, without Flutter or product services.

## Strategy parameters

The three integer percentages are non-negative and must total 100:

1. **Max own cells** — maximize the AI's living-cell count after the move and
   one evolution.
2. **Min their cells** — minimize the opponent's living-cell count after the
   move and one evolution.
3. **Max own minus theirs** — maximize the resulting population advantage.

The balanced default is 34%, 33%, and 33% respectively.

For each AI turn, the first 32 bits of the current SHA-256 state hash select a
bucket from 0 through 99. The configured percentage ranges map that bucket to
one strategy. This gives the requested per-turn strategy mix without storing a
random-number-generator state, and replaying or reopening the same position
always produces the same AI decision.

## One-step move selection

The agent applies every legal move with the canonical engine. Moves that
produce equal successor states are grouped and evaluated once. It scores each
unique successor only on the strategy selected for that turn, chooses the best
score, and uses the first row-major coordinate to break ties.

The AI never predicts the opponent's next turn. Multi-step search, learned
weights, remote inference, and adaptive difficulty are outside this version.

## Headless strategy experiments

`OneStepExperimentRunner` runs reusable profiles as ordered Black and White
pairings. The default profiles are the three pure strategies plus an equal
three-way mix represented by the integer percentages 34%, 33%, and 33%. The
default matrix therefore contains 16 pairings; a pure-only run contains nine.

Repeating the original row-major agent from the canonical opening would always
produce the same game, which cannot measure a useful win rate. Experiment
trials instead use separate non-negative tie-break seeds for Black and White.
The seed selects among distinct equal-scoring best successor states using a
SHA-256 digest; it never selects a lower-scoring move for that turn's selected
objective or changes the engine. Trial seeds, outcomes, and final state hashes
can be emitted for exact reproduction. The unseeded product agent continues to
use the first row-major coordinate.

## Mixture optimization

`OneStepAdaptiveOptimizer` searches for independent Black and White mixtures
without Flutter or product services. It begins with the three pure profiles
and equal mix, estimates their zero-sum payoff matrix, and uses deterministic
fictitious play to approximate the restricted-game equilibrium.

For each color, the opponent equilibrium becomes the target distribution for
an adaptive best-response search. The search starts with all 66 mixtures on a
10-point simplex grid, then refines promising regions at 5%, 2%, and 1% while
retaining deterministic global exploration points. At each resolution,
candidates receive a small common-seed budget, uncertain or strong survivors
receive a larger budget, and five finalists receive the largest budget. A
discovered response is added to its color's strategy league before the payoff
matrix is solved again.

The final audit searches once more against both equilibrium distributions.
Separate robust single-profile recommendations maximize Black's worst-case
payoff and minimize White's worst-case Black payoff within the discovered
league. Holdout games use a disjoint seed range and deterministic percentile
bootstrap confidence intervals. Reported exploitability is the gap between
the final externally searched Black and White best-response payoffs, rather
than an Elo rating; the full non-transitive payoff matrix is retained.

## Turn control

- In player vs AI, the human previews and confirms a move normally. The AI then
  responds once before the updated local game is saved and returned to the
  human. If the AI is Black, it makes exactly one opening move when the match is
  created or restarted.
- In AI vs AI, no turn runs automatically. The board is read-only and each
  press of **Next step** computes, saves, and displays exactly one AI move. This
  prevents a match from finishing immediately without observation.

## Persistence and compatibility

Local game configuration stores each color's participant type and the three AI
percentages. Existing saved games that predate these fields load as human vs
human with the balanced default, so the secure local-game schema does not need
a breaking version change.
