# Phase 9 P16 — Phase 3B, Phase 8 and Phase 9 side by side

| fixture | generator | offered | mean abs distance error | mean quality | mean repeated ground | u-turns | worst overlap among offered | GraphHopper calls | search / routing wall |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | Phase 3B | 3 | 345 m | 69.3 | 0.27% | 0 | 37.8% | 238 | 476 ms |
| douglas-5km | Phase 8 (quoted) | 3 | 88 m | 72.7 | 0.00% | 0 | — | see report | — |
| douglas-5km | Phase 9 S2 | 3 | 29 m | 73.5 | 0.00% | 1 | 21.4% | 0 | 370 ms |
| douglas-3km | Phase 3B | 3 | 206 m | 66.8 | 1.30% | 0 | 25.8% | 96 | 184 ms |
| douglas-3km | Phase 8 (quoted) | 3 | 122 m | 69.5 | 0.00% | 0 | — | see report | — |
| douglas-3km | Phase 9 S2 | 3 | 23 m | 75.4 | 0.00% | 1 | 48.8% | 0 | 155 ms |
| peel-5km | Phase 3B | 3 | 103 m | 70.0 | 1.97% | 1 | 28.0% | 530 | 741 ms |
| peel-5km | Phase 8 (quoted) | 2 | 65 m | 76.5 | 0.00% | 0 | — | see report | — |
| peel-5km | Phase 9 S2 | 3 | 145 m | 66.2 | 0.33% | 2 | 38.5% | 0 | 78 ms |
| onchan-5km | Phase 3B | 3 | 208 m | 64.4 | 3.97% | 0 | 17.4% | 114 | 221 ms |
| onchan-5km | Phase 8 (quoted) | 3 | 83 m | 77.4 | 0.00% | 0 | — | see report | — |
| onchan-5km | Phase 9 S2 | 3 | 17 m | 77.8 | 0.00% | 0 | 31.4% | 0 | 96 ms |

## Ring totals

| generator | offered / 12 | mean abs error | mean quality | mean repeated | total u-turns | GraphHopper calls | total wall |
|---|---:|---:|---:|---:|---:|---:|---:|
| Phase 3B | 12 | 216 m | 67.6 | 1.88% | 1 | 978 | 1622 ms |
| Phase 8 (quoted) | 11 | 92 m | 73.8 | 0.00% | 0 | 924 + 64 probes | — |
| Phase 9 S2 | 12 | 54 m | 73.2 | 0.08% | 4 | 0 | 699 ms |

## Phase 9 cost detail

| fixture | subgraph export ms | graph build ms | search ms | states expanded |
|---|---:|---:|---:|---:|
| douglas-5km | 7.66 | 17.6 | 345 | 133194 |
| douglas-3km | 4.26 | 15.8 | 135 | 71580 |
| peel-5km | 1.14 | 2.2 | 75 | 55798 |
| onchan-5km | 3.58 | 5.4 | 88 | 62143 |
