# Phase 9 — direct bounded closed-walk search (offline)

beam 300, band 100 m, per-node cap 3, per-family floor 1, wanted Infinity, band ±12%

## Prototype comparison

| prototype | fixture | closed walks | gate passes | pass rate | offered | states expanded | states generated | pruned: distance | pruned: reuse | pruned: beam | pruned: dominated | peak band | search ms | judge ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| S1 | douglas-5km | 0 | 0 | 0.0% | 0 | 2000000 | 2000000 | 1479391 | 3280495 | 0 | 0 | 214 | 224 | 0 |
| S1 | douglas-3km | 0 | 0 | 0.0% | 0 | 2000000 | 2000001 | 1123233 | 3746945 | 0 | 0 | 142 | 235 | 0 |
| S1 | peel-5km | 0 | 0 | 0.0% | 0 | 2000000 | 2000002 | 1155043 | 2952001 | 0 | 0 | 121 | 345 | 0 |
| S1 | onchan-5km | 0 | 0 | 0.0% | 0 | 2000000 | 2000001 | 810828 | 3434876 | 0 | 0 | 148 | 409 | 0 |
| S2 | douglas-5km | 188 | 156 | 83.0% | 3 | 133194 | 277911 | 4527 | 171882 | 144147 | 75841 | 2970 | 367 | 54 |
| S2 | douglas-3km | 133 | 128 | 96.2% | 3 | 71580 | 150326 | 1884 | 90224 | 78350 | 41380 | 2588 | 118 | 22 |
| S2 | peel-5km | 124 | 66 | 53.2% | 3 | 55798 | 99891 | 1671 | 72506 | 43719 | 33894 | 1587 | 70 | 27 |
| S2 | onchan-5km | 142 | 141 | 99.3% | 3 | 62143 | 115143 | 2294 | 76459 | 52416 | 28998 | 1626 | 94 | 29 |
| S3 | douglas-5km | 140 | 90 | 64.3% | 3 | 131236 | 271483 | 3195 | 172830 | 139007 | 34366 | 985 | 274 | 27 |
| S3 | douglas-3km | 358 | 317 | 88.5% | 3 | 75549 | 155813 | 2684 | 97533 | 79005 | 18141 | 1020 | 116 | 45 |
| S3 | peel-5km | 214 | 116 | 54.2% | 2 | 58811 | 104310 | 2072 | 77199 | 44622 | 15831 | 820 | 72 | 35 |
| S3 | onchan-5km | 100 | 68 | 68.0% | 3 | 65689 | 118582 | 2046 | 83885 | 52112 | 13514 | 570 | 87 | 15 |
| S4 | douglas-5km | 0 | 0 | 0.0% | 0 | 66547 | 139747 | 0 | 84832 | 69573 | 20326 | 3157 | 132 | 0 |
| S4 | douglas-3km | 0 | 0 | 0.0% | 0 | 35750 | 75536 | 0 | 44874 | 36017 | 9420 | 2422 | 65 | 0 |
| S4 | peel-5km | 0 | 0 | 0.0% | 0 | 29778 | 54399 | 0 | 37912 | 23069 | 5116 | 1539 | 48 | 0 |
| S4 | onchan-5km | 0 | 0 | 0.0% | 0 | 37396 | 68296 | 5 | 47664 | 29010 | 6597 | 2154 | 47 | 0 |

## Offered walks

| prototype | fixture | offered | median distance | mean abs error | mean quality | mean compactness | mean repeated % | u-turns | worst physical overlap |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| S1 | douglas-5km | 0 | — | — | — | — | — | — | — |
| S1 | douglas-3km | 0 | — | — | — | — | — | — | — |
| S1 | peel-5km | 0 | — | — | — | — | — | — | — |
| S1 | onchan-5km | 0 | — | — | — | — | — | — | — |
| S2 | douglas-5km | 3 | 4981 | 29 m | 73.5 | 0.318 | 0.00% | 1 | 21.4% |
| S2 | douglas-3km | 3 | 2994 | 23 m | 75.4 | 0.431 | 0.00% | 1 | 48.8% |
| S2 | peel-5km | 3 | 5111 | 145 m | 66.2 | 0.328 | 0.33% | 2 | 38.5% |
| S2 | onchan-5km | 3 | 4982 | 17 m | 77.8 | 0.426 | 0.00% | 0 | 31.4% |
| S3 | douglas-5km | 3 | 4972 | 154 m | 67.1 | 0.262 | 0.00% | 1 | 42.9% |
| S3 | douglas-3km | 3 | 2973 | 19 m | 74.8 | 0.306 | 0.00% | 0 | 34.0% |
| S3 | peel-5km | 2 | 5151 | 152 m | 67.5 | 0.321 | 0.00% | 1 | 2.2% |
| S3 | onchan-5km | 3 | 4593 | 358 m | 63.5 | 0.419 | 0.00% | 0 | 25.7% |
| S4 | douglas-5km | 0 | — | — | — | — | — | — | — |
| S4 | douglas-3km | 0 | — | — | — | — | — | — | — |
| S4 | peel-5km | 0 | — | — | — | — | — | — | — |
| S4 | onchan-5km | 0 | — | — | — | — | — | — | — |

## Rejection classes
```text
S1: none
S2: u-turns=91  start-spur=5  shapeless=1
S3: u-turns=195  out-and-back-spur=19  start-spur=11  shapeless=1
S4: none
```

## Cost per request

| fixture | subgraph export ms | search-graph build ms | S2 search ms | judge ms | total ms | states expanded | store entries | peak heap MB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 7.66 | 16.1 | 367 | 54 | 445 | 133194 | 277915 | 704 |
| douglas-3km | 4.26 | 15.5 | 118 | 22 | 160 | 71580 | 150330 | 704 |
| peel-5km | 1.14 | 2.2 | 70 | 27 | 101 | 55798 | 99897 | 683 |
| onchan-5km | 3.58 | 5.0 | 94 | 29 | 131 | 62143 | 115147 | 682 |

S2 total offered across the normal ring: **12 of 12**
S2 total search time across the ring: 650 ms

