# Game of Life AI screening round — 20,000-ply review

27 of 36 games ended naturally. 9 reached the review limit with both colors alive.

All nine challengers played D2 twice in each color. Each decision had a ceiling of 100,000 generated successors. The 20,000-ply review point was chosen after the screen began.

| ID | As Black (W / L / D / unfinished) | As White (W / L / D / unfinished) | Score bounds vs D2 |
| --- | --- | --- | --- |
| D1 | 0 / 2 / 0 / 0 | 0 / 2 / 0 / 0 | 0% |
| D3 | 2 / 0 / 0 / 0 | 2 / 0 / 0 / 0 | 100% |
| D4 | 1 / 0 / 0 / 1 | 1 / 0 / 0 / 1 | 50%–100% |
| D5 | 1 / 0 / 0 / 1 | 1 / 0 / 0 / 1 | 50%–100% |
| D8 | 1 / 0 / 0 / 1 | 1 / 0 / 0 / 1 | 50%–100% |
| F1B4 | 2 / 0 / 0 / 0 | 2 / 0 / 0 / 0 | 100% |
| F1B8 | 2 / 0 / 0 / 0 | 0 / 0 / 0 / 2 | 50%–100% |
| F2B4 | 1 / 0 / 0 / 1 | 2 / 0 / 0 / 0 | 75%–100% |
| F2B8 | 2 / 0 / 0 / 0 | 2 / 0 / 0 / 0 | 100% |

Each score is out of four scheduled games, counting a win as one point and a draw as half. The lower bound assigns zero points to each unfinished game and the upper bound assigns one.

D2 fell back to a one-ply search on 0 of its 172,313 decisions.
The longest finished game reached 18,508 plies (D3 Black vs D2 White, trial 0, seeds 6000000 and 6000001).

## What to do next

**Leave the nine survivors paused. Compare D3 and F1B4 directly on fresh seeds.** D2 beat D1 four times but lost all 23 decided games against stronger challengers. More games against D2 cannot answer which finalist beats the other.

| ID | Search policy | Wins vs D2 (Black / White) | Mean plies to win (all 4 games) | Mean generated successors per decision |
| --- | --- | --- | ---: | ---: |
| D3 | Full width, depth cap 3 | 2 / 2 | 14,552.25 | 87,885.47 |
| F1B4 | All first moves, then best 4 replies per node | 2 / 2 | 5,307.50 | 99,998.71 |
| F2B8 | All first moves and replies, then best 8 per node | 2 / 2 | 11,786.25 | 100,000.00 |

These three candidates already have the maximum score and maximum worst-color score. Among the two selective candidates with four confirmed wins, the predeclared work tie-break narrowly favors F1B4 over F2B8 (about 1.29 successors per decision, a negligible efficiency difference). Its shorter games are descriptive, not a tie-break or proof that it would win head-to-head. D3 is the only full-width challenger with four confirmed wins. Unresolved challengers could still tie on wins and change the eventual work tie-break; the selections are recommendations for follow-up, not proven rankings.

Six of the nine paused games are D4, D5 and D8 replaying exactly the same 20,000 placements on each of two matched color/seed combinations. This is redundancy on the observed paths, not proof of identical future choices. The other three survivors can be resumed if the precise screening tie-break becomes important.

I recommend prioritizing the 20 direct D3–F1B4 games in the planned fresh-seed confirmation matrix: 10 seed pairs, both color orders. Set the reporting horizon before launch. None of that stage has started, and no product AI level has been changed.

## Verification and data

All **344,619 placements** were replayed from the opening with the original canonical engine. Every saved board, position hash, state hash, and outcome matched. All 27 natural results were eliminations; the nine survivors have no winner or draw recorded.

[Detailed statistics](budgeted-search-20k-progress.md) · [Matched trajectories and game lengths](budgeted-search-20k-trajectories.md) · [Replay audit](budgeted-search-20k-provenance/final-replay.json) · [Executable provenance](budgeted-search-20k-provenance/README.md). Timing distributions mix machine load, suspension and equivalent builds; logical work counts are comparable. The verified checkpoint archive contains the original config, summary and all 36 game histories. Its [SHA-256](budgeted-search-20k-provenance/checkpoint-archive.sha256) identifies the exact review state.
