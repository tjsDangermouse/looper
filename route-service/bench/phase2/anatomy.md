# Looper engine-call anatomy

Six production-probe fixtures, 1863 engine calls, 11862 ms of engine wall time in total.
Wall time is measured at Looper's own call site, so it includes HTTP and JSON on top of the search.

### By request class, all fixtures

| class | calls | total ms | % of engine ms | mean ms | median | p95 | max | visited nodes | mean visited |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| avoid-strong | 1227 | 8130 | 68.5% | 6.63 | 6 | 12 | 30 | 740,762 | 604 |
| plain | 368 | 1886 | 15.9% | 5.13 | 5 | 9 | 12 | 71,240 | 194 |
| avoid-relaxed | 268 | 1846 | 15.6% | 6.89 | 7 | 12 | 17 | 172,316 | 643 |
| **total** | **1863** | **11862** | | | | | | **984,318** | |

### By purpose, all fixtures

| class | calls | total ms | % of engine ms | mean ms | median | p95 | max | visited nodes | mean visited |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| leg | 1024 | 6812 | 57.4% | 6.65 | 6 | 11 | 30 | 502,532 | 491 |
| join-pullback | 422 | 2610 | 22.0% | 6.18 | 6 | 10 | 17 | 110,422 | 262 |
| leg-budget | 201 | 1428 | 12.0% | 7.10 | 7 | 12 | 17 | 157,808 | 785 |
| waypoint-leg | 147 | 634 | 5.3% | 4.31 | 3 | 11 | 16 | 189,402 | 1,288 |
| spike | 59 | 342 | 2.9% | 5.80 | 6 | 11 | 12 | 21,968 | 372 |
| waypoint-direct | 8 | 21 | 0.2% | 2.63 | 3 | 4 | 4 | 2,186 | 273 |
| leg-relaxed | 2 | 15 | 0.1% | 7.50 | 6 | 9 | 9 | 0 | 0 |
| **total** | **1863** | **11862** | | | | | | **984,318** | |

### By class × purpose

| class | calls | total ms | % of engine ms | mean ms | median | p95 | max | visited nodes | mean visited |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| avoid-strong / leg | 811 | 5564 | 46.9% | 6.86 | 7 | 12 | 30 | 462,678 | 571 |
| avoid-strong / join-pullback | 270 | 1735 | 14.6% | 6.43 | 6 | 11 | 17 | 83,952 | 311 |
| avoid-relaxed / leg-budget | 201 | 1428 | 12.0% | 7.10 | 7 | 12 | 17 | 157,808 | 785 |
| plain / leg | 213 | 1248 | 10.5% | 5.86 | 6 | 10 | 12 | 39,854 | 187 |
| avoid-strong / waypoint-leg | 90 | 508 | 4.3% | 5.64 | 5 | 12 | 16 | 173,708 | 1,930 |
| plain / join-pullback | 90 | 491 | 4.1% | 5.46 | 5 | 9 | 12 | 13,506 | 150 |
| avoid-relaxed / join-pullback | 62 | 384 | 3.2% | 6.19 | 5 | 10 | 12 | 12,964 | 209 |
| avoid-strong / spike | 56 | 323 | 2.7% | 5.77 | 6 | 11 | 12 | 20,424 | 365 |
| plain / waypoint-leg | 57 | 126 | 1.1% | 2.21 | 2 | 4 | 4 | 15,694 | 275 |
| plain / waypoint-direct | 8 | 21 | 0.2% | 2.63 | 3 | 4 | 4 | 2,186 | 273 |
| avoid-relaxed / spike | 3 | 19 | 0.2% | 6.33 | 5 | 9 | 9 | 1,544 | 515 |
| avoid-relaxed / leg-relaxed | 2 | 15 | 0.1% | 7.50 | 6 | 9 | 9 | 0 | 0 |
| **total** | **1863** | **11862** | | | | | | **984,318** | |

### Per fixture

| fixture | calls | engine ms | plain | avoid-strong | avoid-relaxed | lower-bound |
|---|---:|---:|---:|---:|---:|---:|
| douglas-3km | 215 | 1435 | 34 / 208ms | 157 / 1067ms | 24 / 160ms | — |
| douglas-5km | 291 | 2244 | 47 / 312ms | 182 / 1423ms | 62 / 509ms | — |
| onchan-5km | 181 | 1298 | 30 / 206ms | 111 / 809ms | 40 / 283ms | — |
| peel-5km | 763 | 3985 | 149 / 710ms | 502 / 2676ms | 112 / 599ms | — |
| wp-one | 34 | 101 | 18 / 35ms | 16 / 66ms | — | — |
| wp-two | 379 | 2799 | 90 / 415ms | 259 / 2089ms | 30 / 295ms | — |

### Corridor count vs cost (avoidance calls only)

| areas | calls | mean ms | mean visited nodes |
|---:|---:|---:|---:|
| 1 | 660 | 6.44 | 631 |
| 2 | 498 | 6.77 | 652 |
| 3 | 245 | 7.01 | 543 |
| 4 | 71 | 6.68 | 466 |
| 5 | 17 | 7.47 | 324 |
| 6 | 4 | 8.75 | 649 |
