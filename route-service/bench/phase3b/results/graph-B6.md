## Call graph: fix-ups by parent

| purpose | calls | with a named parent | distinct parents | calls per parent |
|---|---:|---:|---:|---:|
| `leg` | 815 | 0 | 0 | — |
| `join-pullback` | 260 | 260 | 193 | 1.35 |
| `waypoint-leg` | 147 | 0 | 0 | — |
| `leg-budget` | 142 | 142 | 142 | 1.00 |
| `spike` | 51 | 51 | 51 | 1.00 |
| `waypoint-direct` | 8 | 0 | 0 | — |
| `leg-relaxed` | 3 | 0 | 0 | — |
| **total** | **1426** | | | |

## Fix-up chains per routed leg

| what hangs off one ordinary leg call | legs | share | calls it costs |
|---|---:|---:|---:|
| — nothing | 639 | 66.2% | 639 |
| `join-pullback` | 94 | 9.7% | 188 |
| `leg-budget` | 93 | 9.6% | 186 |
| `join-pullback → join-pullback` | 50 | 5.2% | 150 |
| `spike` | 30 | 3.1% | 60 |
| `leg-budget → join-pullback` | 26 | 2.7% | 78 |
| `leg-budget → join-pullback → join-pullback` | 12 | 1.2% | 48 |
| `leg-budget → spike` | 10 | 1.0% | 30 |
| `spike → join-pullback` | 6 | 0.6% | 18 |
| `spike → join-pullback → join-pullback` | 4 | 0.4% | 16 |
| `leg-budget → spike → join-pullback → join-pullback` | 1 | 0.1% | 5 |
| **total ordinary leg calls** | **965** | | **1426** |

## join-pullback anatomy

260 calls across 193 invocations — 1.35 calls each.

| trigger | invocations | share | median join turn | median pullback movement (m) |
|---|---:|---:|---:|---:|
| turn | 193 | 100.0% | 180 | 476 |

kept: **145 of 193** (75.1%)

pullback movement, metres: mean 571, median 476, p90 973, max 1750
turn straightened where kept, degrees: mean 103, median 123
invocations that paid two calls and left the join no straighter: **48** (24.9%)

| join-pullback invocations on one leg seam | seams |
|---|---:|
| 1 | 193 |

## leg-budget anatomy

142 calls; kept **101** (71.1%).

where kept, metres saved: mean 2233, median 1385, p90 3489, max 15980
the strong leg's length as a multiple of the budget: mean 1.69×, median 1.44×, p90 2.53×

| leg-budget calls on one leg step | steps |
|---|---:|
| 1 | 61 |
| 2 | 12 |
| 3 | 19 |

leg attempts: 665; accepted first time 200; retried 327; of those exhausted 50
retry reasons — over planned length only 178, short backtrack only 0, both 149

leg steps that retried: 182; last attempt closer to planned length than the first: 155, not closer: 27

## Calls per candidate, and what the candidate came to

calls per candidate build: mean 7.7, median 7, p90 13, max 64, over 186 builds

| candidate outcome | builds | GH calls | % of calls | calls per build |
|---|---:|---:|---:|---:|
| failed-quality | 114 | 1086 | 76.2% | 9.5 |
| passed | 27 | 185 | 13.0% | 6.9 |
| abandoned-or-cancelled | 43 | 150 | 10.5% | 3.5 |
| unattributed | 2 | 5 | 0.4% | 2.5 |

| first rejection reason | builds | GH calls | % of calls | calls per build |
|---|---:|---:|---:|---:|
| distance | 76 | 727 | 51.0% | 9.6 |
| out-and-back-spur | 22 | 210 | 14.7% | 9.5 |
| leg-too-long | 6 | 56 | 3.9% | 9.3 |
| u-turns | 4 | 51 | 3.6% | 12.8 |
| shapeless | 4 | 31 | 2.2% | 7.8 |
| repeated-corridor | 2 | 11 | 0.8% | 5.5 |

## Duplicate and near-duplicate questions

| | calls |
|---|---:|
| answered by the exact memo | 88 |
| first legs of a mirrored bearing pair, which ask the identical question | 68 |
| first-leg calls in all | 141 |

## Calls per fixture

| fixture | calls | leg | join-pullback | leg-budget | waypoint-leg | spike | other | memo hits | candidate builds |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-3km | 113 | 80 | 23 | 9 | 0 | 1 | 0 | 7 | 14 |
| douglas-5km | 238 | 153 | 51 | 31 | 0 | 3 | 0 | 12 | 24 |
| onchan-5km | 148 | 97 | 26 | 23 | 0 | 2 | 0 | 8 | 16 |
| peel-5km | 591 | 359 | 126 | 59 | 0 | 44 | 3 | 32 | 66 |
| wp-one | 34 | 0 | 0 | 0 | 32 | 0 | 2 | 0 | 17 |
| wp-two | 302 | 126 | 34 | 20 | 115 | 1 | 6 | 29 | 49 |
| **total** | **1426** | 815 | 260 | 142 | 147 | 51 | 11 | 88 | 186 |
