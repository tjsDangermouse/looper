# Phase 9 P3 — topology of Phase 3B walks

Medians across the four normal fixtures.

| group | walks | unique edges | edge passes | repeated m | repeated % | gate repeated % | max reuse | stem m | stem % | core m | compactness |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| offered | 12 | 140 | 142 | 102 | 2.77% | 1.44% | 2.0 | 4 | 0.10% | 4766 | 0.429 |
| passed | 19 | 139 | 142 | 104 | 2.43% | 1.78% | 2.0 | 7 | 0.15% | 4759 | 0.404 |
| rejected | 84 | 109 | 114 | 262 | 6.52% | 5.33% | 2.0 | 3 | 0.07% | 4194 | 0.151 |
| rejected: shapeless | 52 | 97 | 109 | 366 | 9.58% | 8.21% | 2.0 | 6 | 0.10% | 4168 | 0.114 |
| rejected: out-and-back-spur | 50 | 93 | 99 | 338 | 7.69% | 7.48% | 2.0 | 6 | 0.10% | 3893 | 0.138 |
| rejected: distance | 56 | 95 | 100 | 249 | 6.16% | 4.84% | 2.0 | 7 | 0.10% | 3672 | 0.171 |

## Per fixture, offered walks only

| fixture | walks | distance | unique edges | repeated m | repeated % | max reuse | stem m | stem % | core m | compactness | u-turns |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 3 | 4933 | 213 | 11 | 0.22% | 2.0 | 4 | 0.07% | 4925 | 0.438 | 0.0 |
| douglas-3km | 3 | 2792 | 140 | 99 | 3.10% | 2.0 | 1 | 0.04% | 2790 | 0.419 | 0.0 |
| peel-5km | 3 | 4888 | 105 | 172 | 3.52% | 2.0 | 61 | 1.25% | 4771 | 0.260 | 0.0 |
| onchan-5km | 3 | 4874 | 98 | 264 | 5.42% | 2.0 | 43 | 0.88% | 4788 | 0.537 | 0.0 |

## Distribution over offered walks

```text
unique edges           min    64.000  p25    98.000  median   139.500  p75   149.000  max   213.000  mean   137.167
edge passes            min    68.000  p25   101.000  median   142.000  p75   152.000  max   215.000  mean   140.417
repeated metres        min     1.000  p25    24.000  median   101.500  p75   172.000  max   549.000  mean   137.500
repeated fraction %    min     0.019  p25     0.860  median     2.768  p75     3.761  max    10.362  mean     3.006
gate repeated %        min     0.000  p25     0.537  median     1.439  p75     2.315  max     6.871  mean     1.894
max edge reuse         min     2.000  p25     2.000  median     2.000  p75     2.000  max     2.000  mean     2.000
reused edges           min     1.000  p25     2.000  median     3.000  p75     4.000  max     6.000  mean     3.250
stem edges             min     0.000  p25     1.000  median     1.000  p75     1.000  max     4.000  mean     1.417
stem metres            min     0.000  p25     1.000  median     4.000  p75    43.000  max    61.000  mean    19.250
stem fraction %        min     0.000  p25     0.036  median     0.103  p75     0.882  max     1.250  mean     0.399
compactness            min     0.257  p25     0.319  median     0.429  p75     0.448  max     0.588  mean     0.413
bbox ratio             min     1.101  p25     1.240  median     1.354  p75     1.620  max     2.109  mean     1.439
```
