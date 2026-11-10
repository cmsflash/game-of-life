# Budget-controlled AI experiments — 20,000-ply review snapshot

Snapshot (UTC): 2026-11-10T21:28:45.127275+00:00.

The review round has stopped. All nine checkpoints labeled “active” below are paused at exactly 20,000 plies. See the [decision and interpretation](budgeted-search-20k-review.md).

Win rates mean wins / scheduled games, with draws counted as non-wins. Bounds replace point estimates whenever games are unresolved. Each color-specific cell is reported independently.

## 1. budgeted-search-screen-2026-09-23

Source revision: `6ee821c0c83b0b79c7e0608c159990515a7966bf`; evaluation: `terminalUtilityV1`. Budget: **100,000 unique successors/move**; safety cap: 1,000,000 plies; base seed: 6000000.

27/36 games completed; 0 truncated, 9 active, 0 errored, 0 not started.

Config hash: `1014f085a5a9b014fe89633a1e0c3a9ed79683bdd83604c94cd3ab9ae862e853`. Data: `/Users/zhuoran/Programs/game-of-life/docs/experiments/budgeted-search-screen`.

### Matchups (Black's perspective)

| ID | Black | White | W–L–D | Unfinished (cap/active/error/new) | Black win rate | Completed-only win rate | Finished length mean / median / p90 / max |
| --- | --- | --- | --- | --- | --- | --- | --- |
| M1 | D1 | D2 | 0–2–0 | 0 (0/0/0/0) | 0.0% | 0.0% | 6 / 6 / 6 / 6 |
| M2 | D2 | D1 | 2–0–0 | 0 (0/0/0/0) | 100.0% | 100.0% | 12 / 12 / 15 / 15 |
| M3 | D3 | D2 | 2–0–0 | 0 (0/0/0/0) | 100.0% | 100.0% | 15,740.5 / 15,740.5 / 18,508 / 18,508 |
| M4 | D2 | D3 | 0–2–0 | 0 (0/0/0/0) | 0.0% | 0.0% | 13,364 / 13,364 / 18,195 / 18,195 |
| M5 | D4 | D2 | 1–0–0 | 1 (0/1/0/0) | 50.0%–100.0% (bounds) | 100.0% | 3,249 / 3,249 / 3,249 / 3,249 |
| M6 | D2 | D4 | 0–1–0 | 1 (0/1/0/0) | 0.0%–50.0% (bounds) | 0.0% | 1,523 / 1,523 / 1,523 / 1,523 |
| M7 | D5 | D2 | 1–0–0 | 1 (0/1/0/0) | 50.0%–100.0% (bounds) | 100.0% | 3,249 / 3,249 / 3,249 / 3,249 |
| M8 | D2 | D5 | 0–1–0 | 1 (0/1/0/0) | 0.0%–50.0% (bounds) | 0.0% | 1,523 / 1,523 / 1,523 / 1,523 |
| M9 | D8 | D2 | 1–0–0 | 1 (0/1/0/0) | 50.0%–100.0% (bounds) | 100.0% | 3,249 / 3,249 / 3,249 / 3,249 |
| M10 | D2 | D8 | 0–1–0 | 1 (0/1/0/0) | 0.0%–50.0% (bounds) | 0.0% | 1,523 / 1,523 / 1,523 / 1,523 |
| M11 | F1B4 | D2 | 2–0–0 | 0 (0/0/0/0) | 100.0% | 100.0% | 4,350 / 4,350 / 5,162 / 5,162 |
| M12 | D2 | F1B4 | 0–2–0 | 0 (0/0/0/0) | 0.0% | 0.0% | 6,265 / 6,265 / 11,005 / 11,005 |
| M13 | F1B8 | D2 | 2–0–0 | 0 (0/0/0/0) | 100.0% | 100.0% | 6,002 / 6,002 / 7,846 / 7,846 |
| M14 | D2 | F1B8 | 0–0–0 | 2 (0/2/0/0) | 0.0%–100.0% (bounds) | — | — / — / — / — |
| M15 | F2B4 | D2 | 1–0–0 | 1 (0/1/0/0) | 50.0%–100.0% (bounds) | 100.0% | 6,826 / 6,826 / 6,826 / 6,826 |
| M16 | D2 | F2B4 | 0–2–0 | 0 (0/0/0/0) | 0.0% | 0.0% | 2,426.5 / 2,426.5 / 4,836 / 4,836 |
| M17 | F2B8 | D2 | 2–0–0 | 0 (0/0/0/0) | 100.0% | 100.0% | 9,960.5 / 9,960.5 / 18,310 / 18,310 |
| M18 | D2 | F2B8 | 0–2–0 | 0 (0/0/0/0) | 0.0% | 0.0% | 13,612 / 13,612 / 14,287 / 14,287 |

### Profiles (cross-play only; no self-play outcomes)

| ID | Max depth / full-width prefix / beam | W–L–D / unfinished | Win rate | Black W–L–D | White W–L–D |
| --- | --- | --- | --- | --- | --- |
| D1 | 1 / 64 / 8 | 0–4–0 / 0 | 0.0% | 0–2–0 | 0–2–0 |
| D2 | 2 / 64 / 8 | 4–23–0 / 9 | 11.1%–36.1% (bounds) | 2–11–0 | 2–12–0 |
| D3 | 3 / 64 / 8 | 4–0–0 / 0 | 100.0% | 2–0–0 | 2–0–0 |
| D4 | 4 / 64 / 8 | 2–0–0 / 2 | 50.0%–100.0% (bounds) | 1–0–0 | 1–0–0 |
| D5 | 5 / 64 / 8 | 2–0–0 / 2 | 50.0%–100.0% (bounds) | 1–0–0 | 1–0–0 |
| D8 | 8 / 64 / 8 | 2–0–0 / 2 | 50.0%–100.0% (bounds) | 1–0–0 | 1–0–0 |
| F1B4 | 8 / 1 / 4 | 4–0–0 / 0 | 100.0% | 2–0–0 | 2–0–0 |
| F1B8 | 8 / 1 / 8 | 2–0–0 / 2 | 50.0%–100.0% (bounds) | 2–0–0 | 0–0–0 |
| F2B4 | 8 / 2 / 4 | 3–0–0 / 1 | 75.0%–100.0% (bounds) | 1–0–0 | 2–0–0 |
| F2B8 | 8 / 2 / 8 | 4–0–0 / 0 | 100.0% | 2–0–0 | 2–0–0 |

### Actual search effort (all recorded turns)

| ID | Turns | Transitions mean / p95 / max | Mean budget used | Time ms mean / p50 / p95 / max | Completed horizon counts | Horizon ≥4 / ≥5 | Max visited ply mean / max |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D1 | 17 | 39.24 / 64 / 64 | <0.1% | 0.57 / 0.52 / 1.47 / 1.47 | 1: 17 | 0.0% / 0.0% | 1 / 1 |
| D2 | 172313 | 19,155.62 / 37,245 / 68,948 | 19.2% | 292.77 / 219.86 / 776.23 / 11,657.28 | 2: 172313 | 0.0% / 0.0% | 2 / 2 |
| D3 | 29104 | 87,885.47 / 100,000 / 100,000 | 87.9% | 1,654.01 / 2,004.79 / 2,501.72 / 246,416.7 | 2: 19296, 3: 9808 | 0.0% / 0.0% | 3 / 3 |
| D4 | 22386 | 99,939.71 / 100,000 / 100,000 | >99.9% | 1,541.04 / 2,036.5 / 2,504.28 / 246,452 | 2: 14508, 3: 7843, 4: 35 | 0.2% / 0.0% | 3.35 / 4 |
| D5 | 22386 | 99,994.05 / 100,000 / 100,000 | >99.9% | 1,383.6 / 1,773.63 / 2,487.88 / 246,444.61 | 2: 14508, 3: 7843, 4: 33, 5: 2 | 0.2% / <0.1% | 3.35 / 5 |
| D8 | 22386 | 100,000 / 100,000 / 100,000 | 100.0% | 1,444.36 / 1,999.66 / 2,516.5 / 246,444.92 | 2: 14508, 3: 7843, 4: 33, 5: 1, 6: 1 | 0.2% / <0.1% | 3.35 / 7 |
| F1B4 | 10614 | 99,998.71 / 100,000 / 100,000 | >99.9% | 2,100.22 / 2,160.11 / 2,515.65 / 15,988.84 | 2: 981, 3: 7240, 4: 1954, 5: 381, 6: 48, 7: 8, 8: 2 | 22.5% / 4.1% | 4.17 / 8 |
| F1B8 | 26002 | 100,000 / 100,000 / 100,000 | 100.0% | 1,439.11 / 1,981.57 / 2,439.64 / 246,433.27 | 2: 5235, 3: 20077, 4: 654, 5: 36 | 2.7% / 0.1% | 3.82 / 6 |
| F2B4 | 15839 | 100,000 / 100,000 / 100,000 | 100.0% | 1,652.13 / 2,065.33 / 2,463.21 / 246,482.9 | 2: 10300, 3: 5092, 4: 399, 5: 38, 6: 10 | 2.8% / 0.3% | 3.38 / 7 |
| F2B8 | 23572 | 100,000 / 100,000 / 100,000 | 100.0% | 1,294.87 / 624.09 / 2,397.99 / 246,475.32 | 2: 14892, 3: 8196, 4: 456, 5: 28 | 2.1% / 0.1% | 3.39 / 6 |

### Versus D2 (both scheduled colors)

| ID | W–L–D / unfinished | Win rate | Nominal Wilson 95% |
| --- | --- | --- | --- |
| D1 | 0–4–0 / 0 | 0.0% | 0.0%–49.0% |
| D3 | 4–0–0 / 0 | 100.0% | 51.0%–100.0% |
| D4 | 2–0–0 / 2 | 50.0%–100.0% (bounds) | — |
| D5 | 2–0–0 / 2 | 50.0%–100.0% (bounds) | — |
| D8 | 2–0–0 / 2 | 50.0%–100.0% (bounds) | — |
| F1B4 | 4–0–0 / 0 | 100.0% | 51.0%–100.0% |
| F1B8 | 2–0–0 / 2 | 50.0%–100.0% (bounds) | — |
| F2B4 | 3–0–0 / 1 | 75.0%–100.0% (bounds) | — |
| F2B8 | 4–0–0 / 0 | 100.0% | 51.0%–100.0% |

### Longest observed games (ties retained)

| ID | Status | Black | White | Trial | Plies | Black seed / White seed | Outcome |
| --- | --- | --- | --- | --- | --- | --- | --- |
| L1 | complete | D3 | D2 | 0 | 18508 | 6000000 / 6000001 | black: elimination |
| L2 | active | D4 | D2 | 1 | 20000 | 6000002 / 6000003 | unresolved |
| L3 | active | D2 | D4 | 1 | 20000 | 6000002 / 6000003 | unresolved |
| L4 | active | D5 | D2 | 1 | 20000 | 6000002 / 6000003 | unresolved |
| L5 | active | D2 | D5 | 1 | 20000 | 6000002 / 6000003 | unresolved |
| L6 | active | D8 | D2 | 1 | 20000 | 6000002 / 6000003 | unresolved |
| L7 | active | D2 | D8 | 1 | 20000 | 6000002 / 6000003 | unresolved |
| L8 | active | D2 | F1B8 | 0 | 20000 | 6000000 / 6000001 | unresolved |
| L9 | active | D2 | F1B8 | 1 | 20000 | 6000002 / 6000003 | unresolved |
| L10 | active | F2B4 | D2 | 0 | 20000 | 6000000 / 6000001 | unresolved |

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
