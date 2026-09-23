# Budget-controlled AI experiments — interim snapshot

Snapshot (UTC): 2026-09-23T22:21:03.224002+00:00.

Win rates mean wins / scheduled games, with draws counted as non-wins. Bounds replace point estimates whenever games are unresolved. Each color-specific cell is reported independently.

## 1. budgeted-search-screen-2026-09-23

Source revision: `6ee821c0c83b0b79c7e0608c159990515a7966bf`; evaluation: `terminalUtilityV1`. Budget: **100,000 unique successors/move**; safety cap: 1,000,000 plies; base seed: 6000000.

4/36 games completed; 0 truncated, 18 active, 0 errored, 14 not started.

Config hash: `1014f085a5a9b014fe89633a1e0c3a9ed79683bdd83604c94cd3ab9ae862e853`. Data: `/Users/zhuoran/Programs/game-of-life/docs/experiments/budgeted-search-screen`.

### Matchups (Black's perspective)

| ID | Black | White | W–L–D | Unfinished (cap/active/error/new) | Black win rate | Completed-only win rate | Finished length mean / median / p90 / max |
| --- | --- | --- | --- | --- | --- | --- | --- |
| M1 | D1 | D2 | 0–2–0 | 0 (0/0/0/0) | 0.0% | 0.0% | 6 / 6 / 6 / 6 |
| M2 | D2 | D1 | 2–0–0 | 0 (0/0/0/0) | 100.0% | 100.0% | 12 / 12 / 15 / 15 |
| M3 | D3 | D2 | 0–0–0 | 2 (0/2/0/0) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M4 | D2 | D3 | 0–0–0 | 2 (0/2/0/0) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M5 | D4 | D2 | 0–0–0 | 2 (0/1/0/1) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M6 | D2 | D4 | 0–0–0 | 2 (0/1/0/1) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M7 | D5 | D2 | 0–0–0 | 2 (0/1/0/1) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M8 | D2 | D5 | 0–0–0 | 2 (0/1/0/1) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M9 | D8 | D2 | 0–0–0 | 2 (0/1/0/1) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M10 | D2 | D8 | 0–0–0 | 2 (0/1/0/1) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M11 | F1B4 | D2 | 0–0–0 | 2 (0/1/0/1) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M12 | D2 | F1B4 | 0–0–0 | 2 (0/1/0/1) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M13 | F1B8 | D2 | 0–0–0 | 2 (0/1/0/1) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M14 | D2 | F1B8 | 0–0–0 | 2 (0/1/0/1) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M15 | F2B4 | D2 | 0–0–0 | 2 (0/1/0/1) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M16 | D2 | F2B4 | 0–0–0 | 2 (0/1/0/1) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M17 | F2B8 | D2 | 0–0–0 | 2 (0/1/0/1) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M18 | D2 | F2B8 | 0–0–0 | 2 (0/1/0/1) | 0.0%–100.0% (bounds) | — | — / — / — / — |

### Profiles (cross-play only; no self-play outcomes)

| ID | Max depth / full-width prefix / beam | W–L–D / unfinished | Win rate | Black W–L–D | White W–L–D |
| --- | --- | --- | --- | --- | --- |
| D1 | 1 / 64 / 8 | 0–4–0 / 0 | 0.0% | 0–2–0 | 0–2–0 |
| D2 | 2 / 64 / 8 | 4–0–0 / 32 | 11.1%–100.0% (bounds) | 2–0–0 | 2–0–0 |
| D3 | 3 / 64 / 8 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | 0–0–0 | 0–0–0 |
| D4 | 4 / 64 / 8 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | 0–0–0 | 0–0–0 |
| D5 | 5 / 64 / 8 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | 0–0–0 | 0–0–0 |
| D8 | 8 / 64 / 8 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | 0–0–0 | 0–0–0 |
| F1B4 | 8 / 1 / 4 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | 0–0–0 | 0–0–0 |
| F1B8 | 8 / 1 / 8 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | 0–0–0 | 0–0–0 |
| F2B4 | 8 / 2 / 4 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | 0–0–0 | 0–0–0 |
| F2B8 | 8 / 2 / 8 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | 0–0–0 | 0–0–0 |

### Actual search effort (all recorded turns)

| ID | Turns | Transitions mean / p95 / max | Mean budget used | Time ms mean / p50 / p95 / max | Completed horizon counts | Horizon ≥4 / ≥5 | Max visited ply mean / max |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D1 | 17 | 39.24 / 64 / 64 | <0.1% | 0.57 / 0.52 / 1.47 / 1.47 | 1: 17 | 0.0% / 0.0% | 1 / 1 |
| D2 | 4821 | 17,444.13 / 34,505 / 54,555 | 17.4% | 237.17 / 196.21 / 582.83 / 1,540.85 | 2: 4821 | 0.0% / 0.0% | 2 / 2 |
| D3 | 1362 | 86,556.29 / 100,000 / 100,000 | 86.6% | 1,062.32 / 927.68 / 2,135.89 / 3,966.31 | 2: 908, 3: 454 | 0.0% / 0.0% | 3 / 3 |
| D4 | 1137 | 99,749.37 / 100,000 / 100,000 | 99.7% | 1,164.28 / 936.94 / 2,268.73 / 3,458.99 | 2: 712, 3: 419, 4: 6 | 0.5% / 0.0% | 3.37 / 4 |
| D5 | 1137 | 100,000 / 100,000 / 100,000 | 100.0% | 1,168.3 / 939.27 / 2,280.71 / 3,699.14 | 2: 712, 3: 419, 4: 6 | 0.5% / 0.0% | 3.38 / 5 |
| D8 | 250 | 100,000 / 100,000 / 100,000 | 100.0% | 2,080.34 / 1,989.12 / 2,534.42 / 3,597.65 | 2: 131, 3: 113, 4: 6 | 2.4% / 0.0% | 3.5 / 5 |
| F1B4 | 175 | 100,000 / 100,000 / 100,000 | 100.0% | 2,085.21 / 2,147.34 / 2,612.92 / 3,305.25 | 2: 18, 3: 93, 4: 45, 5: 16, 6: 2, 7: 1 | 36.6% / 10.9% | 4.39 / 8 |
| F1B8 | 250 | 100,000 / 100,000 / 100,000 | 100.0% | 1,971.28 / 1,885.39 / 2,360.05 / 3,415.99 | 2: 15, 3: 189, 4: 36, 5: 10 | 18.4% / 4.0% | 4.15 / 6 |
| F2B4 | 250 | 100,000 / 100,000 / 100,000 | 100.0% | 1,983.07 / 1,890.36 / 2,360.12 / 3,228.9 | 2: 152, 3: 70, 4: 22, 5: 4, 6: 2 | 11.2% / 2.4% | 3.53 / 7 |
| F2B8 | 237 | 100,000 / 100,000 / 100,000 | 100.0% | 1,960.75 / 1,878.17 / 2,390.05 / 3,680.99 | 2: 117, 3: 106, 4: 11, 5: 3 | 5.9% / 1.3% | 3.57 / 6 |

### Versus D2 (both scheduled colors)

| ID | W–L–D / unfinished | Win rate | Nominal Wilson 95% |
| --- | --- | --- | --- |
| D1 | 0–4–0 / 0 | 0.0% | 0.0%–49.0% |
| D3 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | — |
| D4 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | — |
| D5 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | — |
| D8 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | — |
| F1B4 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | — |
| F1B8 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | — |
| F2B4 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | — |
| F2B8 | 0–0–0 / 4 | 0.0%–100.0% (bounds) | — |

### Longest observed games (ties retained)

| ID | Status | Black | White | Trial | Plies | Black seed / White seed | Outcome |
| --- | --- | --- | --- | --- | --- | --- | --- |
| L1 | complete | D2 | D1 | 1 | 15 | 6000002 / 6000003 | black: elimination |
| L2 | active | D2 | D3 | 0 | 1200 | 6000000 / 6000001 | unresolved |

## Interpretation limits

- All games use the same centered 2x2 diagonal opening and elimination rules. Only tie-breaking seeds vary; this does not establish strength across varied openings.
- The budget is a per-move ceiling on generated unique successors, not equal actual work or equal time. Shallow searches can stop early. Runtime also depends on machine load; transitions exclude some hashing and duplicate-generation overhead.
- Full-width early plies followed by a beam are selective search. A winning score from that search is not a full-game proof. Completed horizon is the completed requested horizon, not actual search reach: terminal branches stop earlier. Max visited ply includes work from any partially completed deeper iteration.
- Truncated games are right-censored at the safety cap, not draws. Active, error, and not-started games are separate. Win/score bounds allow every unresolved game to become a loss or win; completed-only rates can be biased by game length.
- Lengths use plies (one player's move). Completed-game lengths exclude unfinished games. Percentiles use nearest rank; medians use the usual middle-value average.
- Per-profile win records exclude self-play and depend on the opponent schedule. Per-turn diagnostics include every recorded move, including self-play and unfinished games.
- Seeds are reused across pairings and colors have distinct seeds. Shared seed trials can correlate outcomes; nominal Wilson intervals are descriptive, not paired or cluster-adjusted inference. Small screening samples and selecting a winner require fresh-seed confirmation.
- D1/D2 denote experiment profiles, not guaranteed identical app behavior: hard-budget fallback and tie-breaking can differ. Multiple input studies are shown separately, not pooled.
- During a live run, each game is read from its latest atomic checkpoint, not a single synchronized tournament instant. Checkpoints are saved every 25 plies and can lag the live positions.
