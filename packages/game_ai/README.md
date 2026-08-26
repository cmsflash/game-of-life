# game_ai

The two supported Max Difference AI levels for Life Duel. This package imports
`game_engine` directly and has no Flutter, network, persistence, or clock
dependency, so it can also be used for headless offline experiments.

## AI level 1

`OneStepMaxDifferenceAgent` applies every legal move with the canonical engine,
groups moves that produce the same successor state, and chooses the successor
with the largest own-minus-opponent living-cell count.

## AI level 2

`TwoStepMaxDifferenceAgent` examines every unique first-move successor and every
legal opponent reply. It scores each first move by the smallest population
advantage an opponent reply can leave, then chooses the move with the largest
worst-case score.

Both agents use a deterministic row-major tie break by default. A non-negative
tie-break seed can select reproducibly among equally good successors without
ever selecting a lower-scoring move.

## Headless matches

`AiMatchRunner` runs any two `GameAgent` implementations against each other.
Callers provide the rules or initial state and a safety ply limit. This keeps
offline experiments on exactly the same rules implementation used by the app.

## Test

```bash
dart test
dart analyze --fatal-infos
```
