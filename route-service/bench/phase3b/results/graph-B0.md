## Call graph: fix-ups by parent

| purpose | calls | with a named parent | distinct parents | calls per parent |
|---|---:|---:|---:|---:|
| `leg` | 1010 | 0 | 0 | — |
| `join-pullback` | 416 | 416 | 208 | 2.00 |
| `leg-budget` | 201 | 201 | 201 | 1.00 |
| `waypoint-leg` | 147 | 0 | 0 | — |
| `spike` | 59 | 59 | 59 | 1.00 |
| `waypoint-direct` | 8 | 0 | 0 | — |
| `leg-relaxed` | 2 | 0 | 0 | — |
| **total** | **1843** | | | |

## Fix-up chains per routed leg

| what hangs off one ordinary leg call | legs | share | calls it costs |
|---|---:|---:|---:|
| — nothing | 764 | 65.9% | 764 |
| `join-pullback → join-pullback` | 148 | 12.8% | 444 |
| `leg-budget` | 141 | 12.2% | 282 |
| `leg-budget → join-pullback → join-pullback` | 47 | 4.1% | 188 |
| `spike` | 33 | 2.8% | 66 |
| `spike → join-pullback → join-pullback` | 13 | 1.1% | 52 |
| `leg-budget → spike` | 13 | 1.1% | 39 |
| **total ordinary leg calls** | **1159** | | **1843** |

## join-pullback anatomy

416 calls across 208 invocations — 2.00 calls each.

| trigger | invocations | share | median join turn | median pullback movement (m) |
|---|---:|---:|---:|---:|
| turn | 208 | 100.0% | 180 | 357 |

kept: **145 of 208** (69.7%)

pullback movement, metres: mean 406, median 357, p90 648, max 1000
turn straightened where kept, degrees: mean 87, median 86
invocations that paid two calls and left the join no straighter: **63** (30.3%)

| join-pullback invocations on one leg seam | seams |
|---|---:|
| 1 | 208 |

## leg-budget anatomy

201 calls; kept **132** (65.7%).

where kept, metres saved: mean 2079, median 1385, p90 3366, max 15980
the strong leg's length as a multiple of the budget: mean 1.57×, median 1.37×, p90 2.18×

| leg-budget calls on one leg step | steps |
|---|---:|
| 1 | 34 |
| 2 | 31 |
| 3 | 35 |

leg attempts: 848; accepted first time 172; retried 570; of those exhausted 145
retry reasons — over planned length only 194, short backtrack only 212, both 164

leg steps that retried: 245; last attempt closer to planned length than the first: 185, not closer: 60

## Calls per candidate, and what the candidate came to

calls per candidate build: mean 9.3, median 9, p90 16, max 64, over 199 builds

| candidate outcome | builds | GH calls | % of calls | calls per build |
|---|---:|---:|---:|---:|
| failed-quality | 129 | 1513 | 82.1% | 11.7 |
| passed | 25 | 175 | 9.5% | 7.0 |
| abandoned-or-cancelled | 43 | 150 | 8.1% | 3.5 |
| unattributed | 2 | 5 | 0.3% | 2.5 |

| first rejection reason | builds | GH calls | % of calls | calls per build |
|---|---:|---:|---:|---:|
| distance | 95 | 1138 | 61.7% | 12.0 |
| out-and-back-spur | 18 | 206 | 11.2% | 11.4 |
| leg-too-long | 6 | 66 | 3.6% | 11.0 |
| u-turns | 4 | 50 | 2.7% | 12.5 |
| shapeless | 4 | 39 | 2.1% | 9.8 |
| leg-too-short | 1 | 9 | 0.5% | 9.0 |
| repeated-corridor | 1 | 5 | 0.3% | 5.0 |

## Duplicate and near-duplicate questions

| | calls |
|---|---:|
| answered by the exact memo | 118 |
| first legs of a mirrored bearing pair, which ask the identical question | 76 |
| first-leg calls in all | 154 |

## Calls per fixture

| fixture | calls | leg | join-pullback | leg-budget | waypoint-leg | spike | other | memo hits | candidate builds |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-3km | 215 | 140 | 56 | 18 | 0 | 1 | 0 | 13 | 20 |
| douglas-5km | 291 | 171 | 66 | 50 | 0 | 4 | 0 | 16 | 24 |
| onchan-5km | 181 | 113 | 40 | 27 | 0 | 1 | 0 | 8 | 17 |
| peel-5km | 743 | 422 | 190 | 79 | 0 | 50 | 2 | 46 | 69 |
| wp-one | 34 | 0 | 0 | 0 | 32 | 0 | 2 | 0 | 17 |
| wp-two | 379 | 164 | 64 | 27 | 115 | 3 | 6 | 35 | 52 |
| **total** | **1843** | 1010 | 416 | 201 | 147 | 59 | 10 | 118 | 199 |
