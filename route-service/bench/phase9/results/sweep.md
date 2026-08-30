# Phase 9 P7/P14/P15 — search cost and dominance sweep

## Beam width (band 100 m, per-node 3, quota on)

| setting | offered / 12 | closed walks | gate passes | states expanded | states generated | peak band | store entries | search ms (ring) | worst fixture ms | heap MB (max) | mean quality | mean abs error |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| beam 50 | 3 | 34 | 16 | 54704 | 106663 | 546 | 106681 | 132 | 64 | 34.0 | 63.3 | 170 m |
| beam 100 | 11 | 166 | 151 | 107197 | 209774 | 1137 | 209792 | 200 | 91 | 47.9 | 65.5 | 176 m |
| beam 200 | 11 | 452 | 377 | 216677 | 428282 | 2072 | 428300 | 405 | 197 | 120.4 | 71.2 | 82 m |
| beam 300 | 12 | 587 | 491 | 322715 | 643271 | 2970 | 643289 | 577 | 290 | 137.0 | 73.2 | 54 m |
| beam 600 | 11 | 776 | 631 | 615051 | 1243601 | 5183 | 1243619 | 1123 | 564 | 212.5 | 75.2 | 76 m |
| beam 1200 | 11 | 818 | 678 | 1167171 | 2404657 | 10103 | 2404675 | 2366 | 1250 | 351.4 | 75.4 | 105 m |

## Band width (beam 300, per-node 3, quota on)

| setting | offered / 12 | closed walks | gate passes | states expanded | states generated | peak band | store entries | search ms (ring) | worst fixture ms | heap MB (max) | mean quality | mean abs error |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| band 100 m | 12 | 587 | 491 | 322715 | 643271 | 2970 | 643289 | 577 | 290 | 137.0 | 73.2 | 54 m |
| band 50 m | 12 | 581 | 491 | 358328 | 723254 | 2286 | 723272 | 659 | 337 | 136.0 | 72.9 | 74 m |
| band 200 m | 11 | 611 | 486 | 298326 | 591581 | 3465 | 591599 | 533 | 247 | 129.9 | 71.0 | 102 m |
| band 400 m | 11 | 586 | 436 | 268363 | 527121 | 5027 | 527139 | 458 | 207 | 106.8 | 71.1 | 88 m |

## Per-node dominance cap (beam 300, band 100 m, quota on)

| setting | offered / 12 | closed walks | gate passes | states expanded | states generated | peak band | store entries | search ms (ring) | worst fixture ms | heap MB (max) | mean quality | mean abs error |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| per-node 3 | 12 | 587 | 491 | 322715 | 643271 | 2970 | 643289 | 577 | 290 | 137.0 | 73.2 | 54 m |
| per-node 1 | 11 | 213 | 193 | 288362 | 593499 | 2363 | 593517 | 524 | 253 | 133.2 | 74.8 | 81 m |
| per-node 2 | 12 | 428 | 375 | 311591 | 629261 | 2667 | 629279 | 554 | 264 | 134.7 | 73.3 | 86 m |
| per-node 6 | 11 | 594 | 486 | 327557 | 643747 | 3840 | 643765 | 600 | 302 | 136.4 | 64.8 | 203 m |
| per-node 12 | 11 | 723 | 634 | 347585 | 673325 | 3890 | 673343 | 597 | 290 | 137.3 | 68.5 | 137 m |

## Diversity quota (beam 300, band 100 m, per-node 3)

| setting | offered / 12 | closed walks | gate passes | states expanded | states generated | peak band | store entries | search ms (ring) | worst fixture ms | heap MB (max) | mean quality | mean abs error |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| quota on | 12 | 587 | 491 | 322715 | 643271 | 2970 | 643289 | 577 | 290 | 137.0 | 73.2 | 54 m |
| quota off | 7 | 618 | 529 | 318309 | 643958 | 2534 | 643976 | 522 | 270 | 136.2 | 74.9 | 74 m |

## Per fixture, the retained operating point

| fixture | closed walks | gate passes | offered | states expanded | peak band | store entries | heap MB | search ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 188 | 156 | 3 | 133194 | 2970 | 277915 | 137.0 | 290 |
| douglas-3km | 133 | 128 | 3 | 71580 | 2588 | 150330 | 102.7 | 116 |
| peel-5km | 124 | 66 | 3 | 55798 | 1587 | 99897 | 83.5 | 76 |
| onchan-5km | 142 | 141 | 3 | 62143 | 1626 | 115147 | 98.6 | 94 |
