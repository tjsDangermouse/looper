# Phase 9 P21 — GraphHopper round_trip

## douglas-5km

seeds 12, routed 12, gate passes 1, offered 1, median distance 4252 m against 5000 m, median |error| 1080 m, median quality 12.6, median compactness 0.021, median repeated 6.60%, worst overlap among offered 0.0%

```text
rejections: distance=9  shapeless=9  out-and-back-spur=7  start-spur=1  u-turns=1
```

## douglas-3km

seeds 12, routed 12, gate passes 1, offered 1, median distance 2517 m against 3000 m, median |error| 483 m, median quality 37.5, median compactness 0.030, median repeated 1.15%, worst overlap among offered 0.0%

```text
rejections: distance=10  shapeless=10  out-and-back-spur=5  start-spur=2  u-turns=1
```

## peel-5km

seeds 12, routed 12, gate passes 1, offered 1, median distance 3961 m against 5000 m, median |error| 1767 m, median quality 23.5, median compactness 0.102, median repeated 5.30%, worst overlap among offered 0.0%

```text
rejections: out-and-back-spur=10  shapeless=10  u-turns=8  distance=7  repeated-corridor=1
```

## onchan-5km

seeds 12, routed 12, gate passes 3, offered 2, median distance 5512 m against 5000 m, median |error| 821 m, median quality 39.8, median compactness 0.025, median repeated 3.25%, worst overlap among offered 1.6%

```text
rejections: distance=6  shapeless=6  out-and-back-spur=3  u-turns=1
```


GraphHopper calls 48, wall 402 ms (8 ms/call)

| fixture | seed | distance | error | pass | quality | compactness | repeated % | u-turns | rejections |
|---|---:|---:|---:|---|---:|---:|---:|---:|---|
| douglas-5km | 1 | 1782 | -64.4% | no | 11.3 | 0.001 | 6.6 | 1 | distance, out-and-back-spur, shapeless |
| douglas-5km | 2 | 3808 | -23.8% | no | 9 | 0.026 | 7.2 | 1 | distance, out-and-back-spur, shapeless, start-spur |
| douglas-5km | 3 | 4032 | -19.4% | no | 46.2 | 0.142 | 0.5 | 0 | distance, shapeless |
| douglas-5km | 4 | 1782 | -64.4% | no | 11.3 | 0.001 | 6.6 | 1 | distance, out-and-back-spur, shapeless |
| douglas-5km | 5 | 4317 | -13.7% | no | 41.8 | 0.118 | 0.1 | 1 | distance, out-and-back-spur, shapeless |
| douglas-5km | 6 | 4632 | -7.4% | no | 13.8 | 0.031 | 7.7 | 2 | out-and-back-spur, u-turns, shapeless |
| douglas-5km | 7 | 7526 | 50.5% | no | 5.1 | 0.007 | 22.3 | 1 | distance, shapeless |
| douglas-5km | 8 | 5070 | 1.4% | yes | 71.1 | 0.352 | 1 | 0 | — |
| douglas-5km | 9 | 1782 | -64.4% | no | 11.3 | 0.001 | 6.6 | 1 | distance, out-and-back-spur, shapeless |
| douglas-5km | 10 | 5124 | 2.5% | no | 57.5 | 0.017 | 0.9 | 1 | shapeless |
| douglas-5km | 11 | 4187 | -16.3% | no | 42.7 | 0.265 | 0.6 | 1 | distance, out-and-back-spur |
| douglas-5km | 12 | 300089 | 5901.8% | no | 5 | 0 | 50 | 1 | distance |
| douglas-3km | 1 | 1782 | -40.6% | no | 11.3 | 0.001 | 6.6 | 1 | distance, out-and-back-spur, shapeless |
| douglas-3km | 2 | 2524 | -15.9% | no | 37.7 | 0.026 | 1 | 1 | distance, shapeless, start-spur |
| douglas-3km | 3 | 2510 | -16.3% | no | 36.5 | 0.004 | 1.2 | 1 | distance, shapeless |
| douglas-3km | 4 | 1387 | -53.8% | no | 43.1 | 0.157 | 0 | 1 | distance, shapeless |
| douglas-3km | 5 | 2945 | -1.8% | yes | 75.4 | 0.492 | 0.2 | 0 | — |
| douglas-3km | 6 | 2628 | -12.4% | no | 37.4 | 0.012 | 1 | 1 | distance, shapeless |
| douglas-3km | 7 | 1849 | -38.4% | no | 18.7 | 0.034 | 3.9 | 2 | distance, out-and-back-spur, u-turns, shapeless |
| douglas-3km | 8 | 3473 | 15.8% | no | 41.2 | 0.295 | 1.1 | 1 | distance, out-and-back-spur |
| douglas-3km | 9 | 1782 | -40.6% | no | 11.3 | 0.001 | 6.6 | 1 | distance, out-and-back-spur, shapeless |
| douglas-3km | 10 | 2537 | -15.4% | no | 42.2 | 0.11 | 0 | 1 | distance, shapeless, start-spur |
| douglas-3km | 11 | 2757 | -8.1% | no | 42.5 | 0.042 | 3.9 | 0 | shapeless |
| douglas-3km | 12 | 1782 | -40.6% | no | 11.3 | 0.001 | 6.6 | 1 | distance, out-and-back-spur, shapeless |
| peel-5km | 1 | 5029 | 0.6% | no | 28.5 | 0.105 | 7.5 | 2 | out-and-back-spur, u-turns, shapeless |
| peel-5km | 2 | 8664 | 73.3% | no | 27.1 | 0.231 | 7.7 | 0 | distance |
| peel-5km | 3 | 3233 | -35.3% | no | 21.2 | 0.099 | 3.6 | 2 | distance, out-and-back-spur, u-turns, shapeless |
| peel-5km | 4 | 3233 | -35.3% | no | 21.2 | 0.099 | 3.6 | 2 | distance, out-and-back-spur, u-turns, shapeless |
| peel-5km | 5 | 819 | -83.6% | no | 0.7 | 0.033 | 21.7 | 2 | distance, repeated-corridor, out-and-back-spur, u-turns, shapeless |
| peel-5km | 6 | 1899 | -62% | no | 1.6 | 0.08 | 8.8 | 2 | distance, out-and-back-spur, u-turns, shapeless |
| peel-5km | 7 | 5245 | 4.9% | yes | 60.2 | 0.376 | 0.7 | 1 | — |
| peel-5km | 8 | 4987 | -0.3% | no | 45.8 | 0.107 | 7 | 1 | out-and-back-spur, shapeless |
| peel-5km | 9 | 5029 | 0.6% | no | 25.9 | 0.105 | 10.2 | 2 | out-and-back-spur, u-turns, shapeless |
| peel-5km | 10 | 4690 | -6.2% | no | 46.9 | 0.12 | 2 | 1 | out-and-back-spur, shapeless |
| peel-5km | 11 | 3233 | -35.3% | no | 21.2 | 0.099 | 3.6 | 2 | distance, out-and-back-spur, u-turns, shapeless |
| peel-5km | 12 | 3233 | -35.3% | no | 21.2 | 0.099 | 3.6 | 2 | distance, out-and-back-spur, u-turns, shapeless |
| onchan-5km | 1 | 5458 | 9.2% | yes | 47.5 | 0.471 | 4.4 | 0 | — |
| onchan-5km | 2 | 306619 | 6032.4% | no | 5 | 0 | 49.9 | 1 | distance |
| onchan-5km | 3 | 5567 | 11.3% | yes | 6.5 | 0.007 | 36.6 | 1 | — |
| onchan-5km | 4 | 4721 | -5.6% | no | 56.2 | 0.059 | 1.1 | 0 | shapeless |
| onchan-5km | 5 | 5328 | 6.6% | no | 46.3 | 0.123 | 1.8 | 1 | out-and-back-spur, shapeless |
| onchan-5km | 6 | 6074 | 21.5% | no | 5.1 | 0.006 | 35.8 | 1 | distance |
| onchan-5km | 7 | 3713 | -25.7% | no | 39.6 | 0.015 | 0.2 | 1 | distance, out-and-back-spur, shapeless |
| onchan-5km | 8 | 5013 | 0.3% | no | 57.9 | 0.001 | 0.4 | 3 | out-and-back-spur, u-turns, shapeless |
| onchan-5km | 9 | 5458 | 9.2% | yes | 55.2 | 0.471 | 1.8 | 0 | — |
| onchan-5km | 10 | 306619 | 6032.4% | no | 5 | 0 | 49.8 | 1 | distance |
| onchan-5km | 11 | 12174 | 143.5% | no | 5.7 | 0.036 | 24.1 | 1 | distance, shapeless |
| onchan-5km | 12 | 6269 | 25.4% | no | 39.9 | 0.056 | 2.1 | 0 | distance, shapeless |
