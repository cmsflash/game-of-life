# One-step Max Self elimination: complete 100,000-ply sample

Date: 2026-08-27

## Method

This report completes the 100,000-ply follow-up for all 10 trials sampled from
the 99 Max Self self-play games that were still active at 1,000 plies. Exact
trial IDs and tie-break seeds were deterministically replayed from the start
under elimination-only rules. A game still active at 100,000 plies was reported
as truncated without assigning a winner.

The final six trials ran in parallel with a memory-efficient experiment loop
that does not retain every intermediate turn. A recorded 10-ply fixture and
trial 0's recorded 1,000-ply state hash were reproduced exactly before the run.

## Results

| ID | Metric | Result |
| --- | --- | ---: |
| R1 | Sampled games | 10 |
| R2 | Eliminations by 100,000 plies | 9 |
| R3 | Still active at 100,000 plies | 1 |
| R4 | Black wins | 5 |
| R5 | White wins | 4 |
| R6 | Earliest elimination | 5,365 plies |
| R7 | Latest elimination | 93,580 plies |

| ID | Trial | Seeds (Black/White) | Result | Plies |
| --- | ---: | --- | --- | ---: |
| G1 | 0 | 0/1 | Black eliminated White | 14,303 |
| G2 | 19 | 38/39 | White eliminated Black | 93,580 |
| G3 | 30 | 60/61 | White eliminated Black | 8,950 |
| G4 | 48 | 96/97 | Black eliminated White | 55,673 |
| G5 | 52 | 104/105 | Still active | 100,000 |
| G6 | 64 | 128/129 | White eliminated Black | 15,768 |
| G7 | 67 | 134/135 | Black eliminated White | 19,889 |
| G8 | 72 | 144/145 | White eliminated Black | 15,776 |
| G9 | 79 | 158/159 | Black eliminated White | 5,365 |
| G10 | 85 | 170/171 | Black eliminated White | 91,103 |

At the cutoff, unfinished trial 52 had 23 Black cells and 17 White cells. Its
trajectory remains right-censored: it may eliminate later, but this experiment
does not establish that it continues indefinitely.

## Follow-up

Trial 52 was replayed with a 1,000,000-ply safety horizon and White eliminated
Black at ply 102,486. All 10 sampled games therefore finished; see the
[trial 52 follow-up](./one-step-max-self-elimination-1m-trial-52.md).

## Interpretation

The 10,000-ply checkpoint substantially understated eventual termination:
eight games were active then, but seven of those eliminated before 100,000.
Max Self self-play can therefore create extremely long games, including two
observed eliminations after 90,000 plies, without those games necessarily being
infinite.

Raw results are split across the original
[10,000-ply sample](./one-step-max-self-elimination-10k-sample-data.json),
[trial 0](./one-step-max-self-elimination-100k-trial-0-data.json),
[trial 19](./one-step-max-self-elimination-100k-trial-19-data.json), and the
[six-trial remainder](./one-step-max-self-elimination-100k-remainder-data.json).
