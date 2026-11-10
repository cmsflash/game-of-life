# 20,000-ply checkpoint comparison

## Full-width search trajectories

Each pair played D2 in the same color with the same Black and White seeds. The prefix counts identical placements from the opening. The board comparison uses the last ply recorded for both profiles. Each replay was checked against its saved final position hash.

| ID | Color | Trial | Profiles | Shared prefix | Recorded plies | Same board at shared endpoint | First placement difference |
| --- | --- | ---: | --- | ---: | --- | --- | --- |
| M1 | black | 0 | D4 / D5 | 3,248 | 3,249 / 3,249 | no | last move only, same outcome |
| M2 | black | 0 | D4 / D8 | 3,249 | 3,249 / 3,249 | yes | identical through both endpoints |
| M3 | black | 0 | D5 / D8 | 3,248 | 3,249 / 3,249 | no | last move only, same outcome |
| M4 | black | 1 | D4 / D5 | 20,000 | 20,000 / 20,000 | yes | identical through both endpoints |
| M5 | black | 1 | D4 / D8 | 20,000 | 20,000 / 20,000 | yes | identical through both endpoints |
| M6 | black | 1 | D5 / D8 | 20,000 | 20,000 / 20,000 | yes | identical through both endpoints |
| M7 | white | 0 | D4 / D5 | 1,523 | 1,523 / 1,523 | yes | identical through both endpoints |
| M8 | white | 0 | D4 / D8 | 1,523 | 1,523 / 1,523 | yes | identical through both endpoints |
| M9 | white | 0 | D5 / D8 | 1,523 | 1,523 / 1,523 | yes | identical through both endpoints |
| M10 | white | 1 | D4 / D5 | 20,000 | 20,000 / 20,000 | yes | identical through both endpoints |
| M11 | white | 1 | D4 / D8 | 20,000 | 20,000 / 20,000 | yes | identical through both endpoints |
| M12 | white | 1 | D5 / D8 | 20,000 | 20,000 / 20,000 | yes | identical through both endpoints |

Matching paths describe these sampled openings and seeds. Other opponents or positions can expose differences between policies.

## Observed game length

Each challenger played four games. The D2 baseline row covers all 36 games. Each game contributes its saved length through natural completion or the review limit. In a preview, games below the limit contribute only their recorded plies. These descriptive totals do not enter finalist selection.

| ID | Games | Finished | Paused at 20,000 | Still playing | Recorded plies | Mean per game |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| D1 | 4 | 4 | 0 | 0 | 36 | 9.00 |
| D3 | 4 | 4 | 0 | 0 | 58,209 | 14,552.25 |
| D4 | 4 | 2 | 2 | 0 | 44,772 | 11,193.00 |
| D5 | 4 | 2 | 2 | 0 | 44,772 | 11,193.00 |
| D8 | 4 | 2 | 2 | 0 | 44,772 | 11,193.00 |
| F1B4 | 4 | 4 | 0 | 0 | 21,230 | 5,307.50 |
| F1B8 | 4 | 2 | 2 | 0 | 52,004 | 13,001.00 |
| F2B4 | 4 | 3 | 1 | 0 | 31,679 | 7,919.75 |
| F2B8 | 4 | 4 | 0 | 0 | 47,145 | 11,786.25 |
| D2 | 36 | 27 | 9 | 0 | 344,619 | 9,572.75 |
