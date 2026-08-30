# Phase 7 graph-anchor offline analysis

## Bounded exploration cost

| fixture | limit m | nodes | edges | median warm ms | heap delta |
|---|---:|---:|---:|---:|---:|
| douglas-5km | 1750 | 4520 | 12261 | 3.33 | 832400 |
| douglas-3km | 1050 | 2828 | 7760 | 1.48 | 732728 |
| peel-5km | 1750 | 1149 | 2895 | 0.56 | 416224 |
| onchan-5km | 1750 | 2108 | 5219 | 0.99 | 524288 |

## Shell and angular availability

| fixture | shell width | populated shells | 15° sectors represented | median degree | max angular gap |
|---|---:|---:|---:|---:|---:|
| douglas-5km | 250 | 7 | 20/24 | 3 | 75° |
| douglas-3km | 150 | 7 | 24/24 | 3 | 15° |
| peel-5km | 250 | 7 | 15/24 | 3 | 105° |
| onchan-5km | 250 | 7 | 24/24 | 3 | 15° |

## Candidate results

| fixture | family | built | pass | short | long | other | calls | calls/pass | median guide miss | median abs error | median trim retention |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | A | 24 | 0 | 0 | 24 | 0 | 116 | 116.0 | 0.0 | 2483 | 0.985 |
| douglas-5km | B | 24 | 2 | 0 | 20 | 2 | 147 | 73.5 | 0.0 | 1598 | 0.979 |
| douglas-3km | A | 24 | 15 | 1 | 7 | 1 | 149 | 9.9 | 0.0 | 276 | 0.990 |
| douglas-3km | B | 24 | 9 | 4 | 11 | 0 | 144 | 16.0 | 0.0 | 598 | 0.992 |
| peel-5km | A | 24 | 1 | 7 | 12 | 4 | 172 | 172.0 | 0.0 | 1224 | 0.992 |
| peel-5km | B | 24 | 1 | 1 | 14 | 8 | 156 | 156.0 | 0.0 | 1180 | 0.996 |
| onchan-5km | A | 24 | 7 | 2 | 13 | 2 | 148 | 21.1 | 0.0 | 893 | 0.995 |
| onchan-5km | B | 24 | 8 | 2 | 11 | 3 | 150 | 18.8 | 0.0 | 625 | 0.998 |

## Anchor probe predictability

| fixture | family | anchors | median network/crow stretch | median first-leg network-distance error | median endpoint miss | median anchor-to-anchor routed/crow |
|---|---|---:|---:|---:|---:|---:|
| douglas-5km | A | 72 | 1.23 | 21.0 m | 0.0 m | 1.68 |
| douglas-5km | B | 72 | 1.25 | 33.9 m | 0.0 m | 1.42 |
| douglas-3km | A | 72 | 1.23 | 215.5 m | 0.0 m | 1.18 |
| douglas-3km | B | 72 | 1.26 | 16.8 m | 0.0 m | 1.24 |
| peel-5km | A | 72 | 1.24 | 364.5 m | 0.0 m | 1.26 |
| peel-5km | B | 72 | 1.22 | 8.9 m | 0.0 m | 1.48 |
| onchan-5km | A | 72 | 1.29 | 331.3 m | 0.0 m | 1.31 |
| onchan-5km | B | 72 | 1.30 | 29.1 m | 0.0 m | 1.26 |

## Repair work

| family | candidates | calls/candidate | relaxed | leg-budget | pullback | spike | calls on rejected |
|---|---:|---:|---:|---:|---:|---:|---:|
| A | 96 | 6.09 | 0 | 35 | 161 | 5 | 434 |
| B | 96 | 6.22 | 0 | 49 | 154 | 10 | 478 |

## Offered quality and diversity

| family | offered | mean abs error | mean quality | mean repeated | u-turns | worst geometric overlap | worst physical overlap |
|---|---:|---:|---:|---:|---:|---:|---:|
| A | 7 | 121 m | 76.7 | 0.01% | 0 | 51.9% | 50.7% |
| B | 9 | 245 m | 71.0 | 0.07% | 1 | 15.4% | 8.6% |

## Preprocessing accounting

| fixture | family | exploration ms | selection ms | routing elapsed ms | total analysis path ms | summed GH engine route ms | summed route boundary wall ms |
|---|---|---:|---:|---:|---:|---:|---:|
| douglas-5km | A | 3.33 | 371.72 | 435.5 | 810.5 | 240.0 | 1126.3 |
| douglas-5km | B | 3.33 | 469.27 | 265.4 | 738.0 | 268.1 | 748.1 |
| douglas-3km | A | 1.48 | 407.17 | 213.3 | 622.0 | 192.0 | 569.2 |
| douglas-3km | B | 1.48 | 407.62 | 223.7 | 632.8 | 183.8 | 572.9 |
| peel-5km | A | 0.56 | 121.12 | 224.1 | 345.8 | 132.6 | 606.2 |
| peel-5km | B | 0.56 | 111.16 | 189.5 | 301.3 | 115.5 | 479.6 |
| onchan-5km | A | 0.99 | 246.85 | 194.8 | 442.7 | 130.3 | 547.3 |
| onchan-5km | B | 0.99 | 239.52 | 203.4 | 443.9 | 140.1 | 535.9 |
