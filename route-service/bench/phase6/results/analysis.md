# Phase 6 perimeter attribution — corpus-P6

127 completed candidates; 1311 attributed transformations.

## Outcome counts

| outcome | candidates |
|---|---:|
| PASS | 24 |
| TOO_SHORT | 48 |
| TOO_LONG | 20 |
| OTHER_QUALITY_FAILURE | 35 |

## Per-leg intended versus achieved endpoint progress

| fixture | outcome | attempts | median intended reach | median achieved reach | median guide miss | p90 guide miss | retries | relaxed |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | PASS | 28 | 1021 | 1008 | 11 | 102 | 8 | 0 |
| douglas-5km | TOO_SHORT | 30 | 1157 | 1143 | 28 | 654 | 10 | 8 |
| douglas-5km | TOO_LONG | 41 | 1048 | 1075 | 41 | 393 | 17 | 7 |
| douglas-5km | OTHER_QUALITY_FAILURE | 54 | 960 | 1072 | 231 | 800 | 22 | 7 |
| douglas-3km | PASS | 20 | 713 | 694 | 8 | 457 | 4 | 0 |
| douglas-3km | TOO_SHORT | 23 | 713 | 609 | 62 | 292 | 7 | 1 |
| douglas-3km | TOO_LONG | 14 | 529 | 543 | 10 | 144 | 6 | 1 |
| douglas-3km | OTHER_QUALITY_FAILURE | 11 | 649 | 608 | 149 | 307 | 3 | 1 |
| peel-5km | PASS | 27 | 1000 | 985 | 56 | 314 | 9 | 0 |
| peel-5km | TOO_SHORT | 158 | 1250 | 1231 | 192 | 1288 | 57 | 23 |
| peel-5km | TOO_LONG | 27 | 1298 | 1297 | 74 | 828 | 8 | 4 |
| peel-5km | OTHER_QUALITY_FAILURE | 101 | 1128 | 1063 | 72 | 704 | 37 | 11 |
| onchan-5km | PASS | 27 | 1145 | 1062 | 45 | 382 | 7 | 3 |
| onchan-5km | TOO_SHORT | 22 | 1107 | 1109 | 19 | 114 | 10 | 8 |
| onchan-5km | TOO_LONG | 18 | 1000 | 925 | 32 | 237 | 6 | 3 |
| onchan-5km | OTHER_QUALITY_FAILURE | 10 | 1035 | 1034 | 100 | 384 | 2 | 0 |
| wp-two | PASS | 29 | 1676 | 1675 | 18 | 401 | 9 | 2 |
| wp-two | TOO_SHORT | 36 | 1889 | 1606 | 160 | 1069 | 16 | 4 |
| wp-two | TOO_LONG | 18 | 1533 | 1592 | 456 | 1035 | 6 | 4 |
| wp-two | OTHER_QUALITY_FAILURE | 30 | 1922 | 1713 | 16 | 1059 | 6 | 4 |

## Mechanism attribution by outcome

| mechanism | outcome | triggers | mean delta | median delta | p75 abs | p90 abs | total delta | controllable |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| closure | PASS | 24 | 164 | 209 | 280 | 363 | 3933 | 0 |
| closure | TOO_SHORT | 48 | 825 | 373 | 897 | 1258 | 39577 | 0 |
| closure | TOO_LONG | 20 | 1916 | 749 | 1380 | 2239 | 38325 | 0 |
| closure | OTHER_QUALITY_FAILURE | 35 | 1431 | 478 | 988 | 1331 | 50099 | 0 |
| final-trim | PASS | 24 | -46 | -32 | 78 | 105 | -1100 | 0 |
| final-trim | TOO_SHORT | 48 | -135 | -135 | 243 | 277 | -6500 | 0 |
| final-trim | TOO_LONG | 20 | -170 | -197 | 252 | 269 | -3408 | 0 |
| final-trim | OTHER_QUALITY_FAILURE | 35 | -160 | -182 | 261 | 280 | -5612 | 0 |
| join-pullback | PASS | 12 | -528 | -524 | 702 | 1040 | -6331 | 9 |
| join-pullback | TOO_SHORT | 64 | -768 | -620 | 1064 | 1776 | -49152 | 19 |
| join-pullback | TOO_LONG | 13 | -486 | -363 | 1666 | 2515 | -6324 | 6 |
| join-pullback | OTHER_QUALITY_FAILURE | 41 | -554 | -450 | 736 | 1466 | -22723 | 14 |
| leg-budget | PASS | 2 | -2755 | -3701 | 3701 | 3701 | -5509 | 2 |
| leg-budget | TOO_SHORT | 20 | -2423 | -1479 | 2506 | 3366 | -48467 | 8 |
| leg-budget | TOO_LONG | 10 | -2933 | -1434 | 2790 | 2931 | -29334 | 5 |
| leg-budget | OTHER_QUALITY_FAILURE | 7 | -5850 | -3222 | 13879 | 14927 | -40951 | 2 |
| replanning | PASS | 70 | -65 | -0 | 261 | 434 | -4533 | 46 |
| replanning | TOO_SHORT | 125 | 171 | 0 | 465 | 763 | 21435 | 77 |
| replanning | TOO_LONG | 55 | -152 | -0 | 600 | 1100 | -8358 | 35 |
| replanning | OTHER_QUALITY_FAILURE | 101 | 8 | 0 | 435 | 826 | 858 | 66 |
| retry | PASS | 29 | -623 | -539 | 766 | 1123 | -18057 | 16 |
| retry | TOO_SHORT | 65 | -1053 | -865 | 1354 | 2000 | -68462 | 31 |
| retry | TOO_LONG | 24 | -775 | -727 | 1000 | 1364 | -18599 | 14 |
| retry | OTHER_QUALITY_FAILURE | 46 | -726 | -675 | 927 | 1353 | -33386 | 21 |
| routing-displacement | PASS | 70 | 379 | 226 | 581 | 901 | 26563 | 46 |
| routing-displacement | TOO_SHORT | 125 | 282 | 247 | 1189 | 1807 | 35231 | 77 |
| routing-displacement | TOO_LONG | 55 | 1054 | 414 | 2089 | 3491 | 57963 | 35 |
| routing-displacement | OTHER_QUALITY_FAILURE | 101 | 479 | 244 | 925 | 1906 | 48358 | 66 |
| spike | PASS | 4 | -59 | -59 | 59 | 59 | -236 | 0 |
| spike | TOO_SHORT | 12 | -54 | -59 | 327 | 327 | -645 | 0 |
| spike | TOO_LONG | 1 | 1068 | 1068 | 1068 | 1068 | 1068 | 1 |
| spike | OTHER_QUALITY_FAILURE | 5 | 156 | -59 | 416 | 543 | 782 | 0 |

### Mechanism attribution by fixture

| fixture | mechanism | triggers | median delta | total delta |
|---|---|---:|---:|---:|
| douglas-5km | closure | 24 | 145 | 7331 |
| douglas-5km | final-trim | 24 | -149 | -3199 |
| douglas-5km | join-pullback | 29 | -461 | -15879 |
| douglas-5km | leg-budget | 8 | -1597 | -13866 |
| douglas-5km | replanning | 72 | -0 | -3769 |
| douglas-5km | retry | 36 | -659 | -23747 |
| douglas-5km | routing-displacement | 72 | 293 | 47168 |
| douglas-5km | spike | 1 | 1068 | 1068 |
| douglas-3km | closure | 12 | 251 | 3362 |
| douglas-3km | final-trim | 12 | -72 | -1138 |
| douglas-3km | join-pullback | 15 | -508 | -6530 |
| douglas-3km | leg-budget | 2 | -2790 | -3987 |
| douglas-3km | replanning | 36 | 0 | 517 |
| douglas-3km | retry | 14 | -335 | -4752 |
| douglas-3km | routing-displacement | 36 | 176 | 12606 |
| peel-5km | closure | 59 | 555 | 39929 |
| peel-5km | final-trim | 59 | -135 | -8067 |
| peel-5km | join-pullback | 59 | -687 | -47419 |
| peel-5km | leg-budget | 17 | -1385 | -31794 |
| peel-5km | replanning | 147 | 0 | 14346 |
| peel-5km | retry | 70 | -853 | -68946 |
| peel-5km | routing-displacement | 147 | 255 | 55730 |
| peel-5km | spike | 21 | -59 | -99 |
| onchan-5km | closure | 13 | 171 | 5902 |
| onchan-5km | final-trim | 13 | -50 | -1209 |
| onchan-5km | join-pullback | 11 | -448 | -6561 |
| onchan-5km | leg-budget | 6 | -1808 | -10623 |
| onchan-5km | replanning | 39 | -0 | -1218 |
| onchan-5km | retry | 18 | -647 | -11751 |
| onchan-5km | routing-displacement | 39 | 268 | 23664 |
| wp-two | closure | 19 | 478 | 75410 |
| wp-two | final-trim | 19 | -197 | -3007 |
| wp-two | join-pullback | 16 | -457 | -8141 |
| wp-two | leg-budget | 6 | -14927 | -63991 |
| wp-two | replanning | 57 | -0 | -474 |
| wp-two | retry | 26 | -1079 | -29307 |
| wp-two | routing-displacement | 57 | 409 | 28948 |

### Mechanism attribution by leg stage

| stage | mechanism | triggers | median delta | p90 absolute delta |
|---:|---|---:|---:|---:|
| 0 | retry | 31 | -541 | 2000 |
| 0 | routing-displacement | 127 | 202 | 735 |
| 1 | closure | 7 | 856 | 4399 |
| 1 | join-pullback | 55 | -540 | 1356 |
| 1 | leg-budget | 24 | -1385 | 3222 |
| 1 | replanning | 127 | -110 | 845 |
| 1 | retry | 70 | -761 | 1364 |
| 1 | routing-displacement | 120 | 484 | 2842 |
| 1 | spike | 5 | 221 | 1068 |
| 2 | closure | 22 | 750 | 1235 |
| 2 | final-trim | 7 | -11 | 214 |
| 2 | join-pullback | 46 | -528 | 1810 |
| 2 | leg-budget | 7 | -2013 | 4681 |
| 2 | replanning | 120 | 0 | 998 |
| 2 | retry | 59 | -733 | 1529 |
| 2 | routing-displacement | 98 | 293 | 2017 |
| 2 | spike | 10 | -59 | 416 |
| 3 | closure | 92 | 316 | 1380 |
| 3 | final-trim | 22 | -190 | 270 |
| 3 | join-pullback | 27 | -447 | 2152 |
| 3 | leg-budget | 7 | -13879 | 15980 |
| 3 | replanning | 98 | -0 | 0 |
| 3 | retry | 4 | -689 | 1353 |
| 3 | routing-displacement | 6 | 101 | 2100 |
| 3 | spike | 5 | -59 | 327 |
| 4 | closure | 6 | 237 | 1496 |
| 4 | final-trim | 92 | -105 | 280 |
| 4 | join-pullback | 2 | -1097 | 1097 |
| 4 | leg-budget | 1 | -1187 | 1187 |
| 4 | replanning | 6 | 0 | 0 |
| 4 | spike | 2 | -59 | 59 |
| 5 | final-trim | 6 | -205 | 261 |

## Peel contrast

| fixture | candidates | median guide miss | p90 guide miss | retry attempts / candidate | kept leg-budget / candidate | kept pullbacks / candidate | negative replan metres / candidate | median closure delta | short-backtrack retry triggers |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 24 | 47 | 600 | 2.38 | 0.33 | 1.21 | 586 | 145 | 39 |
| douglas-3km | 12 | 15 | 377 | 1.67 | 0.17 | 1.25 | 172 | 251 | 4 |
| peel-5km | 59 | 85 | 888 | 1.88 | 0.29 | 1.00 | 196 | 555 | 62 |
| onchan-5km | 13 | 34 | 364 | 1.92 | 0.46 | 0.85 | 396 | 171 | 11 |

## Retention curves

Retention is `(actual routed metres already committed + current remaining crow skeleton) / initial crow skeleton`. Final uses the post-trim routed distance. It is an effective-scale diagnostic, not a claim that crow and network metres are interchangeable.

| outcome | initial | after leg 1 | after leg 2 | after leg 3 | before closure | final |
|---|---:|---:|---:|---:|---:|---:|
| PASS | 1.000 | 1.000 | 0.974 | 0.982 | 0.975 | 0.986 |
| TOO_SHORT | 1.000 | 1.001 | 0.954 | 0.803 | 0.763 | 0.730 |
| TOO_LONG | 1.000 | 1.002 | 1.062 | 1.189 | 1.189 | 1.249 |

### Retention by fixture and outcome (final median)

| fixture | pass | too short | too long |
|---|---:|---:|---:|
| douglas-5km | 0.887 | 0.749 | 1.215 |
| douglas-3km | 0.935 | 0.648 | 1.148 |
| peel-5km | 0.977 | 0.706 | 1.309 |
| onchan-5km | 1.007 | 0.805 | 1.173 |

## Candidate waterfall examples

### douglas-5km:0-ccw@3 — PASS

Initial crow skeleton 5000 m; final routed/trimmed distance 4424 m.

| stage | effective scale before leg | retention | replan delta |
|---:|---:|---:|---:|
| 0 | 5000 | 1.000 | 0 |
| 1 | 5005 | 1.001 | -299 |
| 2 | 4560 | 0.912 | -528 |
| 3 | 4291 | 0.858 | -0 |

Transformation deltas: routing-displacement@0 +308 m; replanning@1 -299 m; retry@1 -668 m; routing-displacement@1 +758 m; replanning@2 -528 m; retry@2 -504 m; routing-displacement@2 +224 m; replanning@3 -0 m; closure@3 +145 m; final-trim@4 -12 m.
### peel-5km:8-cw@3 — TOO_SHORT

Initial crow skeleton 5000 m; final routed/trimmed distance 3320 m.

| stage | effective scale before leg | retention | replan delta |
|---:|---:|---:|---:|
| 0 | 5000 | 1.000 | 0 |
| 1 | 5000 | 1.000 | -154 |
| 2 | 4769 | 0.954 | 262 |
| 3 | 3815 | 0.763 | 0 |

Transformation deltas: routing-displacement@0 +460 m; replanning@1 -154 m; routing-displacement@1 +1324 m; replanning@2 +262 m; routing-displacement@2 -1807 m; replanning@3 +0 m; closure@3 -176 m; leg-budget@1 -1385 m; join-pullback@1 -689 m; final-trim@4 -261 m.
### douglas-5km:8-ccw@3 — TOO_LONG

Initial crow skeleton 5000 m; final routed/trimmed distance 5818 m.

| stage | effective scale before leg | retention | replan delta |
|---:|---:|---:|---:|
| 0 | 5000 | 1.000 | 0 |
| 1 | 5006 | 1.001 | -346 |
| 2 | 6061 | 1.212 | -1100 |
| 3 | 6061 | 1.212 | 0 |

Transformation deltas: routing-displacement@0 +574 m; replanning@1 -346 m; retry@1 -659 m; routing-displacement@1 +3691 m; replanning@2 -1100 m; routing-displacement@2 -393 m; replanning@3 +0 m; closure@3 -7 m; leg-budget@1 -900 m; final-trim@4 -235 m.

## Controllability ranking

Score = total absolute delta × mean early-weight × controllable-trigger share. Early weight is remaining outward legs divided by corner count; it is zero at/after closure.

| rank | mechanism | absolute metres | mean early weight | controllable share | score |
|---:|---|---:|---:|---:|---:|
| 1 | routing-displacement | 279188 | 0.68 | 63.8% | 121319 |
| 2 | retry | 138503 | 0.59 | 50.0% | 40713 |
| 3 | leg-budget | 124261 | 0.43 | 43.6% | 23263 |
| 4 | replanning | 96954 | 0.32 | 63.8% | 19743 |
| 5 | join-pullback | 96926 | 0.36 | 36.9% | 12962 |
| 6 | spike | 4465 | 0.08 | 4.5% | 17 |
| 7 | closure | 138623 | 0.00 | 0.0% | 0 |
| 8 | final-trim | 16620 | 0.00 | 0.0% | 0 |

## Conservative offline correction ceiling

A mechanism recovers a distance failure only when its signed cumulative pre-closure delta opposes the final error, reaches the accepted-band deficit, and the required correction is no more than 30% of the remaining outward planned crow reach at the earliest matching event. This is an oracle ceiling, not a production prediction.

| mechanism | failures recoverable | unique recoveries |
|---|---:|---:|
| closure | 0 / 68 (0.0%) | 0 |
| final-trim | 0 / 68 (0.0%) | 0 |
| join-pullback | 5 / 68 (7.4%) | 0 |
| leg-budget | 3 / 68 (4.4%) | 0 |
| replanning | 9 / 68 (13.2%) | 2 |
| retry | 15 / 68 (22.1%) | 7 |
| routing-displacement | 17 / 68 (25.0%) | 14 |
| spike | 0 / 68 (0.0%) | 0 |
| combined-cumulative-deficit | 38 / 68 (55.9%) | 4 |

### Combined recovery by fixture

| fixture | failures | recoverable |
|---|---:|---:|
| douglas-5km | 11 | 8 (72.7%) |
| douglas-3km | 6 | 3 (50.0%) |
| peel-5km | 37 | 14 (37.8%) |
| onchan-5km | 6 | 5 (83.3%) |
| wp-two | 8 | 8 (100.0%) |

**Gate: GO** — combined conservative recovery is 38/68 (55.9%) across 4 non-waypoint fixtures; the production threshold is 40% and the result must be generic.
