# Ruleset `life-duel` version 2

- The board is a finite 20 by 20 grid. Outside the board is dead.
- Black moves first.
- The initial centered 2 by 2 block gives Black the northwest/southeast
  diagonal and White the other diagonal.
- A turn must place the moving player's cell on an empty square. Passing and
  replacement are not allowed.
- The placement is considered alive, then the entire board evolves
  simultaneously once.
- A live cell survives with two or three live neighbors and keeps its color.
- A dead cell is born with exactly three live neighbors and belongs to the
  player whose move triggered the evolution.
- An isolated placement may die during the same turn. The turn still counts.
- Mutual extinction is a draw. If exactly one color has no cells, the other
  color wins.
- A full nonterminal board with no legal placement is a draw.

Supported victory configurations are elimination, population at an even ply
limit, and first population target. Elimination always takes precedence. If
both colors cross a target during the same simultaneous evolution, the result
is a draw.

Stored version 1 matches and replays remain supported. In version 1 only, a
newborn cell receives the strict majority color of its three live neighbors.
