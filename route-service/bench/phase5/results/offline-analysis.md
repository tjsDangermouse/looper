# Phase 5 full-shape offline analysis — ../phase4/corpus-P5_FULL

482 intermediate states from 128 completed candidates.

## P1 — distance-failure anatomy

| fixture | outcome | candidates | median final error (m) |
|---|---|---:|---:|
| douglas-5km | PASS | 5 | -567 |
| douglas-5km | TOO_SHORT | 5 | -1253 |
| douglas-5km | TOO_LONG | 6 | 1074 |
| douglas-5km | OTHER_QUALITY_FAILURE | 8 | -62 |
| douglas-3km | PASS | 4 | -194 |
| douglas-3km | TOO_SHORT | 4 | -1056 |
| douglas-3km | TOO_LONG | 2 | 445 |
| douglas-3km | OTHER_QUALITY_FAILURE | 2 | 11 |
| peel-5km | PASS | 5 | -115 |
| peel-5km | TOO_SHORT | 31 | -1472 |
| peel-5km | TOO_LONG | 6 | 1545 |
| peel-5km | OTHER_QUALITY_FAILURE | 17 | -207 |
| onchan-5km | PASS | 5 | 34 |
| onchan-5km | TOO_SHORT | 4 | -1205 |
| onchan-5km | TOO_LONG | 3 | 866 |
| onchan-5km | OTHER_QUALITY_FAILURE | 2 | 21 |
| wp-two | PASS | 5 | -25 |
| wp-two | TOO_SHORT | 5 | -1578 |
| wp-two | TOO_LONG | 3 | 3235 |
| wp-two | OTHER_QUALITY_FAILURE | 6 | 107 |

## P2/P3 — estimator accuracy by stage

| stage | estimator | n | median abs (m) | p75 | p90 | median bias | under / over | classification accuracy |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 0 | F0 | 128 | 731 | 1350 | 2114 | 350 | 47 / 81 | 46.1% |
| 0 | F1 | 128 | 2129 | 3053 | 3787 | 2125 | 6 / 122 | 15.6% |
| 0 | F2 | 128 | 2129 | 3053 | 3787 | 2125 | 6 / 122 | 15.6% |
| 0 | F3 | 128 | 2129 | 3053 | 3787 | 2125 | 6 / 122 | 15.6% |
| 1 | F0 | 128 | 722 | 1433 | 2031 | 238 | 48 / 80 | 50.8% |
| 1 | F1 | 128 | 1647 | 2585 | 3217 | 1605 | 10 / 118 | 18.8% |
| 1 | F2 | 128 | 1434 | 2375 | 3585 | 1304 | 14 / 114 | 25.8% |
| 1 | F3 | 128 | 1573 | 2581 | 3179 | 1543 | 11 / 117 | 19.5% |
| 2 | F0 | 121 | 613 | 1072 | 1548 | 87 | 56 / 65 | 59.5% |
| 2 | F1 | 121 | 924 | 1805 | 2380 | 882 | 17 / 104 | 37.2% |
| 2 | F2 | 121 | 1130 | 1980 | 2725 | 1063 | 11 / 110 | 35.5% |
| 2 | F3 | 121 | 1008 | 1939 | 2545 | 943 | 11 / 110 | 35.5% |
| 3 | F0 | 99 | 254 | 659 | 1208 | -97 | 62 / 37 | 71.7% |
| 3 | F1 | 99 | 335 | 771 | 1327 | 194 | 24 / 75 | 68.7% |
| 3 | F2 | 99 | 423 | 847 | 1580 | 187 | 28 / 71 | 68.7% |
| 3 | F3 | 99 | 411 | 765 | 1455 | 205 | 25 / 74 | 68.7% |
| 4 | F0 | 6 | 151 | 833 | 933 | 37 | 2 / 4 | 83.3% |
| 4 | F1 | 6 | 507 | 754 | 986 | 472 | 2 / 4 | 66.7% |
| 4 | F2 | 6 | 427 | 1129 | 1325 | 375 | 2 / 4 | 50.0% |
| 4 | F3 | 6 | 454 | 951 | 1212 | 414 | 2 / 4 | 50.0% |

### Predictability by corner count, stage, and final outcome (F0)

| corners | stage | final outcome | states | F0 predicts same distance class | median final error (m) |
|---:|---:|---|---:|---:|---:|
| 1 | 0 | PASS | 1 | 1 (100.0%) | -123 |
| 1 | 0 | TOO_SHORT | 5 | 0 (0.0%) | -2114 |
| 1 | 0 | TOO_LONG | 1 | 0 (0.0%) | 2196 |
| 1 | 1 | PASS | 1 | 1 (100.0%) | -123 |
| 1 | 1 | TOO_SHORT | 5 | 5 (100.0%) | -2114 |
| 1 | 1 | TOO_LONG | 1 | 0 (0.0%) | 2196 |
| 2 | 0 | PASS | 1 | 1 (100.0%) | -273 |
| 2 | 0 | TOO_SHORT | 11 | 0 (0.0%) | -1497 |
| 2 | 0 | TOO_LONG | 3 | 0 (0.0%) | 1545 |
| 2 | 0 | OTHER_QUALITY_FAILURE | 7 | 7 (100.0%) | 220 |
| 2 | 1 | PASS | 1 | 1 (100.0%) | -273 |
| 2 | 1 | TOO_SHORT | 11 | 0 (0.0%) | -1497 |
| 2 | 1 | TOO_LONG | 3 | 0 (0.0%) | 1545 |
| 2 | 1 | OTHER_QUALITY_FAILURE | 7 | 7 (100.0%) | 220 |
| 2 | 2 | PASS | 1 | 1 (100.0%) | -273 |
| 2 | 2 | TOO_SHORT | 11 | 7 (63.6%) | -1497 |
| 2 | 2 | TOO_LONG | 3 | 2 (66.7%) | 1545 |
| 2 | 2 | OTHER_QUALITY_FAILURE | 7 | 3 (42.9%) | 220 |
| 3 | 0 | PASS | 21 | 21 (100.0%) | -68 |
| 3 | 0 | TOO_SHORT | 31 | 0 (0.0%) | -1303 |
| 3 | 0 | TOO_LONG | 16 | 0 (0.0%) | 1245 |
| 3 | 0 | OTHER_QUALITY_FAILURE | 25 | 25 (100.0%) | -62 |
| 3 | 1 | PASS | 21 | 21 (100.0%) | -68 |
| 3 | 1 | TOO_SHORT | 31 | 0 (0.0%) | -1303 |
| 3 | 1 | TOO_LONG | 16 | 1 (6.3%) | 1245 |
| 3 | 1 | OTHER_QUALITY_FAILURE | 25 | 25 (100.0%) | -62 |
| 3 | 2 | PASS | 21 | 21 (100.0%) | -68 |
| 3 | 2 | TOO_SHORT | 31 | 3 (9.7%) | -1303 |
| 3 | 2 | TOO_LONG | 16 | 6 (37.5%) | 1245 |
| 3 | 2 | OTHER_QUALITY_FAILURE | 25 | 25 (100.0%) | -62 |
| 3 | 3 | PASS | 21 | 19 (90.5%) | -68 |
| 3 | 3 | TOO_SHORT | 31 | 24 (77.4%) | -1303 |
| 3 | 3 | TOO_LONG | 16 | 9 (56.3%) | 1245 |
| 3 | 3 | OTHER_QUALITY_FAILURE | 25 | 16 (64.0%) | -62 |
| 4 | 0 | PASS | 1 | 1 (100.0%) | -115 |
| 4 | 0 | TOO_SHORT | 2 | 0 (0.0%) | -1085 |
| 4 | 0 | OTHER_QUALITY_FAILURE | 3 | 3 (100.0%) | 226 |
| 4 | 1 | PASS | 1 | 1 (100.0%) | -115 |
| 4 | 1 | TOO_SHORT | 2 | 0 (0.0%) | -1085 |
| 4 | 1 | OTHER_QUALITY_FAILURE | 3 | 3 (100.0%) | 226 |
| 4 | 2 | PASS | 1 | 1 (100.0%) | -115 |
| 4 | 2 | TOO_SHORT | 2 | 0 (0.0%) | -1085 |
| 4 | 2 | OTHER_QUALITY_FAILURE | 3 | 3 (100.0%) | 226 |
| 4 | 3 | PASS | 1 | 1 (100.0%) | -115 |
| 4 | 3 | TOO_SHORT | 2 | 0 (0.0%) | -1085 |
| 4 | 3 | OTHER_QUALITY_FAILURE | 3 | 2 (66.7%) | 226 |
| 4 | 4 | PASS | 1 | 1 (100.0%) | -115 |
| 4 | 4 | TOO_SHORT | 2 | 1 (50.0%) | -1085 |
| 4 | 4 | OTHER_QUALITY_FAILURE | 3 | 3 (100.0%) | 226 |

### Accuracy by fixture and stage (median absolute error, metres)

| fixture | stage | F0 | F1 | F2 | F3 |
|---|---:|---:|---:|---:|---:|
| douglas-5km | 0 | 570 | 1811 | 1811 | 1811 |
| douglas-5km | 1 | 573 | 1572 | 1147 | 1429 |
| douglas-5km | 2 | 434 | 883 | 1174 | 957 |
| douglas-5km | 3 | 175 | 357 | 559 | 504 |
| douglas-3km | 0 | 350 | 1244 | 1244 | 1244 |
| douglas-3km | 1 | 438 | 944 | 997 | 868 |
| douglas-3km | 2 | 352 | 469 | 644 | 380 |
| douglas-3km | 3 | 177 | 211 | 250 | 227 |
| peel-5km | 0 | 1089 | 2432 | 2432 | 2432 |
| peel-5km | 1 | 763 | 1849 | 1860 | 1918 |
| peel-5km | 2 | 686 | 1034 | 1207 | 1272 |
| peel-5km | 3 | 433 | 526 | 628 | 519 |
| peel-5km | 4 | 151 | 507 | 427 | 454 |
| onchan-5km | 0 | 295 | 1716 | 1716 | 1716 |
| onchan-5km | 1 | 291 | 1288 | 1139 | 1291 |
| onchan-5km | 2 | 341 | 686 | 999 | 723 |
| onchan-5km | 3 | 199 | 224 | 134 | 187 |
| wp-two | 0 | 836 | 2824 | 2824 | 2824 |
| wp-two | 1 | 836 | 2054 | 2266 | 1718 |
| wp-two | 2 | 771 | 1238 | 1297 | 1161 |
| wp-two | 3 | 458 | 257 | 338 | 235 |

### Accepted-band classification matrices


F0: rows are actual, columns predicted.

| stage / actual | TOO_SHORT | ACCEPTABLE | TOO_LONG |
|---|---:|---:|---:|
| 0 / TOO_SHORT | 0 | 49 | 0 |
| 0 / ACCEPTABLE | 0 | 59 | 0 |
| 0 / TOO_LONG | 0 | 20 | 0 |
| 1 / TOO_SHORT | 5 | 41 | 3 |
| 1 / ACCEPTABLE | 0 | 59 | 0 |
| 1 / TOO_LONG | 1 | 18 | 1 |
| 2 / TOO_SHORT | 10 | 34 | 0 |
| 2 / ACCEPTABLE | 3 | 54 | 1 |
| 2 / TOO_LONG | 2 | 9 | 8 |
| 3 / TOO_SHORT | 24 | 8 | 1 |
| 3 / ACCEPTABLE | 12 | 38 | 0 |
| 3 / TOO_LONG | 1 | 6 | 9 |
| 4 / TOO_SHORT | 1 | 1 | 0 |
| 4 / ACCEPTABLE | 0 | 4 | 0 |

F1: rows are actual, columns predicted.

| stage / actual | TOO_SHORT | ACCEPTABLE | TOO_LONG |
|---|---:|---:|---:|
| 0 / TOO_SHORT | 0 | 0 | 49 |
| 0 / ACCEPTABLE | 0 | 0 | 59 |
| 0 / TOO_LONG | 0 | 0 | 20 |
| 1 / TOO_SHORT | 5 | 0 | 44 |
| 1 / ACCEPTABLE | 0 | 0 | 59 |
| 1 / TOO_LONG | 0 | 1 | 19 |
| 2 / TOO_SHORT | 6 | 15 | 23 |
| 2 / ACCEPTABLE | 1 | 22 | 35 |
| 2 / TOO_LONG | 1 | 1 | 17 |
| 3 / TOO_SHORT | 17 | 13 | 3 |
| 3 / ACCEPTABLE | 4 | 39 | 7 |
| 3 / TOO_LONG | 0 | 4 | 12 |
| 4 / TOO_SHORT | 1 | 1 | 0 |
| 4 / ACCEPTABLE | 0 | 3 | 1 |

F2: rows are actual, columns predicted.

| stage / actual | TOO_SHORT | ACCEPTABLE | TOO_LONG |
|---|---:|---:|---:|
| 0 / TOO_SHORT | 0 | 0 | 49 |
| 0 / ACCEPTABLE | 0 | 0 | 59 |
| 0 / TOO_LONG | 0 | 0 | 20 |
| 1 / TOO_SHORT | 4 | 6 | 39 |
| 1 / ACCEPTABLE | 0 | 13 | 46 |
| 1 / TOO_LONG | 0 | 4 | 16 |
| 2 / TOO_SHORT | 7 | 14 | 23 |
| 2 / ACCEPTABLE | 1 | 20 | 37 |
| 2 / TOO_LONG | 1 | 2 | 16 |
| 3 / TOO_SHORT | 18 | 13 | 2 |
| 3 / ACCEPTABLE | 4 | 37 | 9 |
| 3 / TOO_LONG | 0 | 3 | 13 |
| 4 / TOO_SHORT | 1 | 1 | 0 |
| 4 / ACCEPTABLE | 0 | 2 | 2 |

F3: rows are actual, columns predicted.

| stage / actual | TOO_SHORT | ACCEPTABLE | TOO_LONG |
|---|---:|---:|---:|
| 0 / TOO_SHORT | 0 | 0 | 49 |
| 0 / ACCEPTABLE | 0 | 0 | 59 |
| 0 / TOO_LONG | 0 | 0 | 20 |
| 1 / TOO_SHORT | 5 | 0 | 44 |
| 1 / ACCEPTABLE | 0 | 1 | 58 |
| 1 / TOO_LONG | 0 | 1 | 19 |
| 2 / TOO_SHORT | 7 | 11 | 26 |
| 2 / ACCEPTABLE | 1 | 19 | 38 |
| 2 / TOO_LONG | 1 | 1 | 17 |
| 3 / TOO_SHORT | 18 | 13 | 2 |
| 3 / ACCEPTABLE | 4 | 37 | 9 |
| 3 / TOO_LONG | 0 | 3 | 13 |
| 4 / TOO_SHORT | 1 | 1 | 0 |
| 4 / ACCEPTABLE | 0 | 2 | 2 |

## Radius monotonicity

| stage | states | non-decreasing with non-zero control range over 0.7×…1.3× |
|---:|---:|---:|
| 0 | 128 | 128 (100.0%) |
| 1 | 128 | 121 (94.5%) |
| 2 | 121 | 96 (79.3%) |
| 3 | 99 | 6 (6.1%) |
| 4 | 6 | 0 (0.0%) |

## P4 — conservative theoretical correction ceiling

A failure is counted only when the estimator predicts the correct failure side and the sampled radius range has enough predicted movement in that direction to cover the oracle metres needed to reach the accepted band. This establishes geometric opportunity, not guaranteed network recovery.

| stage | estimator | failures observed | predictably bad | plausibly correctable |
|---:|---|---:|---:|---:|
| 0 | F0 | 69 | 0 (0.0%) | 0 (0.0%) |
| 0 | F1 | 69 | 20 (29.0%) | 17 (24.6%) |
| 0 | F2 | 69 | 20 (29.0%) | 17 (24.6%) |
| 0 | F3 | 69 | 20 (29.0%) | 17 (24.6%) |
| 1 | F0 | 69 | 6 (8.7%) | 1 (1.4%) |
| 1 | F1 | 69 | 24 (34.8%) | 13 (18.8%) |
| 1 | F2 | 69 | 20 (29.0%) | 11 (15.9%) |
| 1 | F3 | 69 | 24 (34.8%) | 13 (18.8%) |
| 2 | F0 | 63 | 18 (28.6%) | 1 (1.6%) |
| 2 | F1 | 63 | 23 (36.5%) | 6 (9.5%) |
| 2 | F2 | 63 | 23 (36.5%) | 6 (9.5%) |
| 2 | F3 | 63 | 24 (38.1%) | 6 (9.5%) |
| 3 | F0 | 49 | 33 (67.3%) | 0 (0.0%) |
| 3 | F1 | 49 | 29 (59.2%) | 0 (0.0%) |
| 3 | F2 | 49 | 31 (63.3%) | 0 (0.0%) |
| 3 | F3 | 49 | 31 (63.3%) | 0 (0.0%) |
| 4 | F0 | 2 | 1 (50.0%) | 0 (0.0%) |
| 4 | F1 | 2 | 1 (50.0%) | 0 (0.0%) |
| 4 | F2 | 2 | 1 (50.0%) | 0 (0.0%) |
| 4 | F3 | 2 | 1 (50.0%) | 0 (0.0%) |

### Unique failures recoverable at any pre-closure stage

| estimator | all distance failures | recoverable | no-waypoint failures | recoverable |
|---|---:|---:|---:|---:|
| F0 | 69 | 2 (2.9%) | 61 | 2 (3.3%) |
| F1 | 69 | 17 (24.6%) | 61 | 14 (23.0%) |
| F2 | 69 | 17 (24.6%) | 61 | 14 (23.0%) |
| F3 | 69 | 17 (24.6%) | 61 | 14 (23.0%) |
