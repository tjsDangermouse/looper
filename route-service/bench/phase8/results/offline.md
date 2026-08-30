# Phase 8 pairwise anchor compatibility — offline analysis

Pool 32, fanout 6, probe budget 16, 2 sequence per directional family.

## P1 — field seeding

| fixture | nodes | edges | warm ms | median &#124;field − routed&#124; (P8 virtual-node seed) | same anchors, P7 tower-node seed | median routed/field |
|---|---:|---:|---:|---:|---:|---:|
| douglas-5km | 4521 | 12263 | 4.01 | 17.7 m | 18.2 m | 1.015 |
| douglas-3km | 2829 | 7762 | 1.63 | 9.3 m | 9.4 m | 1.016 |
| peel-5km | 1149 | 2895 | 0.53 | 6.7 m | 6.7 m | 1.007 |
| onchan-5km | 2120 | 5245 | 1.05 | 0.0 m | 7.5 m | 1.000 |

## P2 — anchor pool

| fixture | pool | 15° sectors | largest angular gap | network distance p10/median/p90 | median degree | median crow separation |
|---|---:|---:|---:|---:|---:|---:|
| douglas-5km | 32 | 20/24 | 45° | 421 / 913 / 1621 m | 4 | 1032 m |
| douglas-3km | 32 | 19/24 | 45° | 328 / 702 / 1015 m | 4 | 730 m |
| peel-5km | 32 | 14/24 | 105° | 440 / 941 / 1633 m | 3 | 852 m |
| onchan-5km | 32 | 21/24 | 30° | 471 / 1143 / 1722 m | 3 | 1215 m |

## P16 — pool size

| fixture | pool | sparse edges | sequences | families | median predicted error | best predicted error | within ±12% band |
|---|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 8 | 56 | 32 | 16 | 276 m | 6 m | 24 |
| douglas-5km | 12 | 130 | 36 | 18 | 94 m | 12 m | 33 |
| douglas-5km | 16 | 192 | 40 | 20 | 87 m | 23 m | 40 |
| douglas-5km | 20 | 240 | 44 | 22 | 87 m | 0 m | 44 |
| douglas-5km | 24 | 288 | 44 | 22 | 60 m | 3 m | 44 |
| douglas-5km | 32 | 384 | 44 | 22 | 32 m | 6 m | 44 |
| douglas-3km | 8 | 56 | 24 | 12 | 208 m | 11 m | 21 |
| douglas-3km | 12 | 130 | 32 | 16 | 115 m | 28 m | 31 |
| douglas-3km | 16 | 192 | 48 | 24 | 66 m | 2 m | 48 |
| douglas-3km | 20 | 240 | 48 | 24 | 47 m | 3 m | 48 |
| douglas-3km | 24 | 288 | 48 | 24 | 36 m | 2 m | 48 |
| douglas-3km | 32 | 384 | 48 | 24 | 30 m | 4 m | 48 |
| peel-5km | 8 | 56 | 20 | 10 | 123 m | 8 m | 16 |
| peel-5km | 12 | 110 | 27 | 14 | 211 m | 1 m | 24 |
| peel-5km | 16 | 162 | 28 | 14 | 119 m | 1 m | 26 |
| peel-5km | 20 | 210 | 28 | 14 | 163 m | 5 m | 25 |
| peel-5km | 24 | 258 | 28 | 14 | 109 m | 0 m | 26 |
| peel-5km | 32 | 356 | 32 | 16 | 64 m | 0 m | 29 |
| onchan-5km | 8 | 56 | 32 | 16 | 446 m | 5 m | 25 |
| onchan-5km | 12 | 132 | 40 | 20 | 201 m | 4 m | 39 |
| onchan-5km | 16 | 192 | 48 | 24 | 77 m | 0 m | 48 |
| onchan-5km | 20 | 240 | 48 | 24 | 109 m | 14 m | 48 |
| onchan-5km | 24 | 288 | 48 | 24 | 66 m | 0 m | 47 |
| onchan-5km | 32 | 384 | 48 | 24 | 63 m | 2 m | 48 |

## P3/P4 — start-tree ancestry against actual pair routes

| shared fraction | pairs | median routed/crow | median routed/tree | median crow | median shared corridor edges |
|---|---:|---:|---:|---:|---:|
| [0, 0.1) | 1499 | 1.310 | 0.881 | 1056 m | 1 |
| [0.1, 0.25) | 232 | 1.402 | 0.759 | 754 m | 7 |
| [0.25, 0.4) | 79 | 1.419 | 0.714 | 575 m | 14 |
| [0.4, 0.6) | 90 | 1.345 | 0.929 | 507 m | 17 |
| [0.6, 1.01) | 84 | 1.245 | 1.000 | 355 m | 26 |

| bearing separation | pairs | median routed/crow | median shared fraction |
|---|---:|---:|---:|
| [0°, 30°) | 381 | 1.348 | 0.281 |
| [30°, 60°) | 381 | 1.420 | 0.033 |
| [60°, 90°) | 328 | 1.369 | 0.005 |
| [90°, 120°) | 326 | 1.314 | 0.000 |
| [120°, 180.1°) | 568 | 1.261 | 0.000 |

Route symmetry: median |A→B − B→A| = 0.0 m.

## P5 — pairwise distance estimators

| fixture | estimator | median abs error | p75 | p90 | median signed bias | median estimate/actual | Spearman rank ρ |
|---|---|---:|---:|---:|---:|---:|---:|
| douglas-5km | E0 crow | 289.5 | 438.5 | 638.5 | -289.5 | 0.780 | 0.942 |
| douglas-5km | E1 tree | 266.8 | 610.0 | 959.0 | 266.8 | 1.198 | 0.780 |
| douglas-5km | E2 bracket midpoint | 161.3 | 287.9 | 413.6 | -15.0 | 0.989 | 0.905 |
| douglas-5km | E2g bracket geometric mean | 153.7 | 249.5 | 367.1 | -48.2 | 0.964 | 0.939 |
| douglas-5km | E3 crow × field stretch | 103.1 | 188.3 | 357.6 | -63.2 | 0.946 | 0.942 |
| douglas-5km | E6 crow × probed stretch (16 probes) | 106.9 | 212.2 | 340.0 | 21.1 | 1.015 | 0.942 |
| douglas-3km | E0 crow | 217.9 | 315.4 | 414.9 | -217.9 | 0.772 | 0.962 |
| douglas-3km | E1 tree | 206.3 | 508.9 | 746.9 | 206.3 | 1.202 | 0.656 |
| douglas-3km | E2 bracket midpoint | 130.1 | 205.7 | 302.7 | -5.8 | 0.993 | 0.885 |
| douglas-3km | E2g bracket geometric mean | 123.1 | 177.9 | 246.3 | -37.2 | 0.952 | 0.940 |
| douglas-3km | E3 crow × field stretch | 71.0 | 129.9 | 241.4 | -64.2 | 0.927 | 0.962 |
| douglas-3km | E6 crow × probed stretch (16 probes) | 65.6 | 125.2 | 191.9 | 10.6 | 1.012 | 0.962 |
| peel-5km | E0 crow | 374.4 | 534.3 | 778.6 | -374.4 | 0.717 | 0.929 |
| peel-5km | E1 tree | 213.8 | 541.7 | 864.2 | 213.8 | 1.155 | 0.835 |
| peel-5km | E2 bracket midpoint | 148.1 | 236.5 | 342.5 | -71.1 | 0.936 | 0.935 |
| peel-5km | E2g bracket geometric mean | 151.3 | 248.2 | 362.5 | -117.9 | 0.899 | 0.958 |
| peel-5km | E3 crow × field stretch | 183.1 | 332.0 | 549.3 | -180.8 | 0.865 | 0.929 |
| peel-5km | E6 crow × probed stretch (16 probes) | 152.3 | 266.7 | 424.5 | 71.9 | 1.075 | 0.929 |
| onchan-5km | E0 crow | 408.9 | 553.1 | 711.2 | -408.9 | 0.755 | 0.960 |
| onchan-5km | E1 tree | 137.9 | 530.6 | 1110.3 | 137.9 | 1.084 | 0.738 |
| onchan-5km | E2 bracket midpoint | 189.6 | 299.3 | 457.5 | -119.7 | 0.930 | 0.922 |
| onchan-5km | E2g bracket geometric mean | 194.7 | 284.5 | 376.4 | -148.0 | 0.914 | 0.960 |
| onchan-5km | E3 crow × field stretch | 122.7 | 226.0 | 369.9 | -81.9 | 0.941 | 0.960 |
| onchan-5km | E6 crow × probed stretch (16 probes) | 113.2 | 213.6 | 362.5 | -10.5 | 0.994 | 0.960 |

## P6/P15 — probe economics

| fixture | pool | pool pairs | probes used | probed stretch | field stretch | oracle capture calls |
|---|---:|---:|---:|---:|---:|---:|
| douglas-5km | 32 | 496 | 16 | 1.301 | 1.213 | 1024 |
| douglas-3km | 32 | 496 | 16 | 1.310 | 1.200 | 1024 |
| peel-5km | 32 | 496 | 16 | 1.499 | 1.207 | 1024 |
| onchan-5km | 32 | 496 | 16 | 1.317 | 1.247 | 1024 |

## P10 — predicted vs actual candidate distance

| fixture | routed | median predicted | median actual | median abs error | p75 | p90 | signed bias | median actual/predicted | in ±12% predicted / in band actual |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 44 | 5012 | 5318 | 765 | 1091 | 1905 | -306 | 1.061 | 44 / 17 |
| douglas-3km | 48 | 2992 | 3263 | 447 | 693 | 1033 | -277 | 1.093 | 48 / 20 |
| peel-5km | 32 | 4980 | 4764 | 494 | 772 | 1188 | 236 | 0.951 | 29 / 17 |
| onchan-5km | 48 | 4996 | 5355 | 726 | 1149 | 1744 | -412 | 1.085 | 48 / 21 |

## P11/P17 — candidate outcomes against Phase 3B

| fixture | generator | built | pass | pass rate | short | long | other | median abs error | calls | calls/pass | calls on rejected |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | Phase 3B | 24 | 5 | 20.8% | 5 | 6 | 8 | — | 238 | 47.6 | 205 |
| douglas-5km | Phase 8 | 44 | 6 | 13.6% | 7 | 20 | 11 | 752 m | 225 | 37.5 | 194 |
| douglas-3km | Phase 3B | 12 | 4 | 33.3% | 4 | 2 | 2 | — | 96 | 24.0 | 72 |
| douglas-3km | Phase 8 | 48 | 14 | 29.2% | 7 | 21 | 6 | 476 m | 235 | 16.8 | 166 |
| peel-5km | Phase 3B | 59 | 5 | 8.5% | 31 | 6 | 17 | — | 530 | 106.0 | 492 |
| peel-5km | Phase 8 | 32 | 2 | 6.3% | 12 | 3 | 15 | 500 m | 212 | 106.0 | 201 |
| onchan-5km | Phase 3B | 13 | 5 | 38.5% | 3 | 3 | 2 | — | 114 | 22.8 | 80 |
| onchan-5km | Phase 8 | 48 | 12 | 25.0% | 5 | 22 | 9 | 671 m | 252 | 21.0 | 194 |
| **total** | Phase 3B | 108 | 19 | 17.6% | 43 | 17 | 29 | — | 978 | 51.5 | 849 |
| **total** | Phase 8 | 172 | 34 | 19.8% | 31 | 66 | 41 | 583 m | 924 | 27.2 | 755 |

## P12 — repair work

| generator | candidates | calls/candidate | geometric retries | leg-budget | join-pullback | spike | relaxed | pullback/candidate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Phase 3B normal | 108 | 9.06 | 213 | 110 | 205 | 45 | 2 | 1.90 |
| Phase 8 | 172 | 5.37 | 0 | 46 | 173 | 17 | 0 | 1.01 |

Median endpoint (guide) miss: 0.0 m. Median trim retention: 0.993.

## P13/P17 — offered routes, quality and diversity

| fixture | Phase 3B offered | Phase 8 offered | mean abs error | mean quality | mean repeated | u-turns | worst geometric overlap | worst physical overlap |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 3 | 3 | 88 m | 72.7 | 0.00% | 0 | 35.6% | 13.8% |
| douglas-3km | 3 | 3 | 122 m | 69.5 | 0.00% | 0 | 26.4% | 22.6% |
| peel-5km | 3 | 2 | 65 m | 76.5 | 0.00% | 0 | 14.8% | 14.9% |
| onchan-5km | 3 | 3 | 83 m | 77.4 | 0.00% | 0 | 24.9% | 21.1% |
| **total** | 12 | 11 | 92 m | 73.8 | 0.00% | 0 | — | — |

## P14 — Peel topology

Pool 32 of a requested 32. Sparse edges 356; sequences 32 across 16 of a possible 24 directional families, against 22–24 on the Douglas and Onchan fixtures.
Median pair shared-tree fraction 0.043; median routed/crow 1.395, the highest of the four fixtures.

| fixture | routed candidates | median planned polygon compactness | median realised compactness | shapeless | out-and-back-spur |
|---|---:|---:|---:|---:|---:|
| douglas-5km | 44 | 0.330 | 0.169 | 27 | 12 |
| douglas-3km | 48 | 0.328 | 0.258 | 13 | 4 |
| peel-5km | 32 | 0.422 | 0.152 | 23 | 22 |
| onchan-5km | 48 | 0.307 | 0.220 | 23 | 16 |

## P9 — directional family diversity

| fixture | families with a sequence | families routed | families with a pass | distinct anchor triples routed | closing anchor re-picked |
|---|---:|---:|---:|---:|---:|
| douglas-5km | 22 | 22 | 6 | 44 | 27 |
| douglas-3km | 24 | 24 | 11 | 46 | 35 |
| peel-5km | 16 | 16 | 2 | 32 | 13 |
| onchan-5km | 24 | 24 | 9 | 46 | 37 |

## Preprocessing and total cost

| fixture | field ms | pool ms | compatibility ms | search ms | probe calls | candidate calls | total calls | routing elapsed ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 4.01 | 0.0 | 17.1 | 18.5 | 16 | 225 | 241 | 770 |
| douglas-3km | 1.63 | 0.0 | 5.5 | 14.6 | 16 | 235 | 251 | 490 |
| peel-5km | 0.53 | 0.0 | 5.8 | 8.8 | 16 | 212 | 228 | 264 |
| onchan-5km | 1.05 | 0.0 | 5.3 | 12.9 | 16 | 252 | 268 | 338 |

Phase 8 total including probes: 988 calls versus Phase 3B 978. Calls on rejected candidates 755 versus 849.
