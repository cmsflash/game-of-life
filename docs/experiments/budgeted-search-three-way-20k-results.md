# Game of Life AI three-way round robin

The 60 games produced 23 Black wins, 24 White wins, 1 natural draw and 12 unfinished games at 20,000 moves. The players made 506,196 moves.

**F2B8 led both opponents.** It won 10 games to D3’s 3, with seven games capped. Even if D3 won all seven, the head-to-head would finish 10–10. F2B8 beat F1B4 by 10 wins to 7 with one draw and two capped games, securing that matchup under every possible outcome of the capped games. D3 led F1B4 by 10 wins to 7 with three capped games.

Across the tournament, F2B8 has already scored 20.5 points from 40 scheduled games. F1B4 can reach at most 19.5. D3 can still reach 23, so the unresolved games leave the overall points lead open between D3 and F2B8. These results describe the ten matched seed pairs and the specified opening.

Each matchup used the same ten fresh pairs of tie-breaking seeds and the centered diagonal opening. The policies swapped colors for the second game of each pair. A win earns one point and a draw earns half. The score ranges show how many points each policy could earn if the capped games were continued.

| ID | Wins | Losses | Draws | Capped | Possible score |
| --- | ---: | ---: | ---: | ---: | ---: |
| D3 | 13 | 17 | 0 | 10 | 13–23 / 40 |
| F1B4 | 14 | 20 | 1 | 5 | 14.5–19.5 / 40 |
| F2B8 | 20 | 10 | 1 | 9 | 20.5–29.5 / 40 |

## Head-to-head results

Each row gives the first policy's record against the second. The color columns show wins, losses, draws and capped games in that order.

| ID | First policy | Second policy | First wins | Second wins | Draws | Capped | First as Black | First as White | First's possible score |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- | ---: |
| M1 | D3 | F1B4 | 10 | 7 | 0 | 3 | 5 / 5 / 0 / 0 | 5 / 2 / 0 / 3 | 10–13 / 20 |
| M2 | D3 | F2B8 | 3 | 10 | 0 | 7 | 2 / 4 / 0 / 4 | 1 / 6 / 0 / 3 | 3–10 / 20 |
| M3 | F1B4 | F2B8 | 7 | 10 | 1 | 2 | 3 / 5 / 1 / 1 | 4 / 5 / 0 / 1 | 7.5–9.5 / 20 |

## Matched seed pairs

A sweep means the same policy won in both colors. A split means the policies won one game each. A pair with either game still unresolved counts as capped.

| ID | Matchup | First swept | Split | Second swept | Fully resolved with a draw | Capped pairs |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| M1 | D3 / F1B4 | 2 | 4 | 1 | 0 | 3 |
| M2 | D3 / F2B8 | 0 | 2 | 2 | 0 | 6 |
| M3 | F1B4 / F2B8 | 1 | 3 | 3 | 1 | 2 |

Each cell gives the first policy's result as Black, then as White. W means win, L loss, D draw and U unfinished at the cap. The Black and White seeds stay with their colors.

| Pair ID | Black / White seed | D3 / F1B4 | D3 / F2B8 | F1B4 / F2B8 |
| --- | --- | --- | --- | --- |
| S1 | 6100000 / 6100001 | L / U | L / L | L / U |
| S2 | 6100002 / 6100003 | L / W | W / L | L / L |
| S3 | 6100004 / 6100005 | W / W | L / W | U / W |
| S4 | 6100006 / 6100007 | L / W | W / U | L / L |
| S5 | 6100008 / 6100009 | W / L | L / U | L / L |
| S6 | 6100010 / 6100011 | W / W | L / L | W / W |
| S7 | 6100012 / 6100013 | L / W | U / L | W / L |
| S8 | 6100014 / 6100015 | L / L | U / L | W / L |
| S9 | 6100016 / 6100017 | W / U | U / U | L / W |
| S10 | 6100018 / 6100019 | W / U | U / L | D / W |

## Search effort

Every decision had a ceiling of 100,000 generated successor positions. Elapsed times combine two verified implementations and varying machine load.

| ID | Decisions | Mean successors per decision | Mean milliseconds per decision |
| --- | ---: | ---: | ---: |
| D3 | 181,225 | 77,421.40 | 15.92 |
| F1B4 | 126,517 | 99,995.36 | 26.12 |
| F2B8 | 198,454 | 99,998.00 | 17.50 |

Study configuration SHA-256 `63ee83c2cdc40614d6529e32d40820c702e49e70224e34b51d403d8514a12abc`.

The single natural draw occurred when both populations died on move 1,080 in F1B4–F2B8, seed pair S10.

## Verification

The original engine independently replayed all 506,196 legal placements and reproduced every final board, state hash and outcome. The unoptimized original AI reproduced eight decisions per game (480 total), including choices in both colors. All sampled moves, scores, depths, search counts and budget flags matched. An equivalent faster implementation completed the later segment. The [methods and build records](three-way-20k-method/README.md) identify the per-game switch boundaries.

[Machine-readable results](three-way-20k-method/results.json) · [Canonical replay audit](three-way-20k-method/final-replay.json) · [Sampled decisions](three-way-20k-method/decision-sample.json) · [Checkpoint archive digest](three-way-20k-method/checkpoints.sha256)
